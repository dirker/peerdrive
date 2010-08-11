%% Hotchpotch
%% Copyright (C) 2010  Jan Klötzke <jan DOT kloetzke AT freenet DOT de>
%%
%% This program is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% This program is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with this program.  If not, see <http://www.gnu.org/licenses/>.

-module(file_store_writer).
-behaviour(gen_server).

-export([start/2]).
-export([read/4, write/4, truncate/3, commit/3, abort/1]).
-export([init/1, handle_call/3, handle_cast/2, code_change/3, handle_info/2, terminate/2]).

-include("store.hrl").
-include("file_store.hrl").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Public interface...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start(State, User) ->
	case gen_server:start(?MODULE, {State, User}, []) of
		{ok, Pid} ->
			{ok, #writer{
				this     = Pid,
				read     = fun read/4,
				write    = fun write/4,
				truncate = fun truncate/3,
				abort    = fun abort/1,
				commit   = fun commit/3
			}};
		Else ->
			Else
	end.

read(Writer, Part, Offset, Length) ->
	gen_server:call(Writer, {read, Part, Offset, Length}).

write(Writer, Part, Offset, Data) ->
	gen_server:call(Writer, {write, Part, Offset, Data}).

truncate(Writer, Part, Offset) ->
	gen_server:call(Writer, {truncate, Part, Offset}).

commit(Writer, Mtime, MergeRevs) ->
	gen_server:call(Writer, {commit, Mtime, MergeRevs}).

abort(Writer) ->
	gen_server:call(Writer, abort).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Callbacks...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init({State, User}) ->
	process_flag(trap_exit, true),
	link(State#ws.server),
	link(User),
	{ok, State}.


% returns: {ok, Data} | eof | {error, Reason}
handle_call({read, Part, Offset, Length}, _From, S) ->
	{S2, File} = get_file_read(S, Part),
	Reply = case File of
		{error, Reason} ->
			{error, Reason};
		IoDevice ->
			file:pread(IoDevice, Offset, Length);
	end,
	{reply, Reply, Handles};

% returns `ok | {error, Reason}'
handle_call({write, Part, Offset, Data}, _From, S) ->
	{S2, File} = get_file_write(S, Part),
	Reply = case File of
		{error, Reason} ->
			{error, Reason};
		IoDevice ->
			file:pwrite(IoDevice, Offset, Data)
	end,
	{reply, Reply, S2};

% returns `ok | {error, Reason}'
handle_call({truncate, Part, Offset}, _From, S) ->
	{S2, File} = get_file_write(S, Part),
	Reply = case File of
		{error, Reason} ->
			{error, Reason};
		IoDevice ->
			file:position(IoDevice, Offset),
			file:truncate(IoDevice)
	end,
	{reply, Reply, S2};

% returns `{ok, Hash} | conflict | {error, Reason}'
handle_call({commit, Mtime, MergeRevs}, _From, S) ->
	do_commit(S, Mtime, MergeRevs);

% returns nothing
handle_call(abort, _From, S) ->
	S2 = do_abort(S),
	{stop, normal, ok, S2}.


handle_info({'EXIT', _From, _Reason}, S) ->
	do_abort(S),
	{stop, orphaned, S}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Stubs...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


handle_cast(_, State)    -> {stop, enotsup, State}.
code_change(_, State, _) -> {ok, State}.
terminate(_, _)          -> ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Local functions...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% returns {S, {error, Reason}} | {S2, IoDevice}
get_file_read(S, Part) ->
	case dict:find(Part, S#ws.readers) of
		{ok, ReadFile} ->
			{S, ReadFile};

		error ->
			case dict:find(Part, S#ws.new) of
				{ok, {_, WriteFile}} ->
					{S, WriteFile};

				error ->
					open_file_read(S, Part)
			end
	end.


open_file_read(S, Part) ->
	case dict:find(Part, S#ws.orig) of
		{ok, Hash} ->
			FileName = util:build_path(S#ws.path, Hash),
			case file:open(FileName, [read, binary]) of
				{ok, IoDevice} ->
					{
						S#ws{readers=dict:store(Part, IoDevice, S#ws.readers)},
						IoDevice
					};

				Error ->
					{S, Error}
			end;

		error ->
			{S, {error, enoent}}
	end,


% returns {S, {error, Reason}} | {S2, IoDevice}
get_file_write(S, Part) ->
	case dict:find(Part, S#ws.new) of
		% we've already opened the part for writing
		{ok, {_, File}} ->
			{S, File};

		% not writing at this part yet...
		error ->
			FileName = util:gen_tmp_name(S#ws.path),
			{S2, FileHandle} = case dict:find(Part, S#ws.orig) of
				% part already exists; copy and open...
				{ok, Hash} ->
					case file:copy(util:build_path(S#ws.path, Hash), FileName) of
						{ok, _} ->
							% release original part, we have our own copy now
							{
								S#ws{orig=dict:erase(Part, S#ws.orig)},
								file:open(FileName, [write, read, binary])
							};
						Error ->
							{S, Error}
					end;

				% doesn't exist yet; create new one...
				error ->
					{S, file:open(FileName, [write, read, binary])}
			end,
			case FileHandle of
				{ok, IoDevice} ->
					{
						S2#ws{
							new=dict:store(Part, {FileName, IoDevice}, S2#ws.new),
							readers=close_reader(Part, S2#ws.readers)},
						IoDevice
					};
				Else2 ->
					{S2, Else2}
			end
	end.


close_reader(Part, Readers) ->
	dict:filter(
		fun
			(Part, IoDevice) -> file:close(IoDevice), false;
			(_, _) -> true
		end,
		Readers).


% calculate hashes, close&move to correct dir, update uuid
% returns {ok, Hash} | conflict | {error, Reason}
do_commit(S, Mtime, MergeRevs) ->
	NewParts = dict:fold(
		% FIXME: this definitely lacks error handling :(
		fun (Part, {TmpName, IODevice}, Acc) ->
			{ok, Hash} = util:hash_file(IODevice),
			file:close(IODevice),
			file_store:lock(S#ws.server, Hash),
			NewName = util:build_path(S#ws.path, Hash),
			case filelib:is_file(NewName) of
				true ->
					file:delete(TmpName);
				false ->
					ok = filelib:ensure_dir(NewName),
					ok = file:rename(TmpName, NewName)
			end,
			[{Part, Hash} | Acc]
		end,
		[],
		S#ws.new),
	NewMergeRevs = case MergeRevs of
		keep -> S#ws.mergerevs;
		_    -> MergeRevs
	end,
	Object = #object{
		flags   = S#ws.flags,
		parts   = lists:usort(NewParts ++ dict:to_list(S#ws.orig)),
		parents = lists:usort(S#ws.baserevs ++ NewMergeRevs),
		mtime   = Mtime,
		uti     = S#ws.uti},
	NewOrig = lists:map(
		fun({Part, Hash}) -> dict:store(Part, Hash, Acc) end,
		S#ws.orig,
		NewParts),
	NewLocks = lists:map(fun({_Part, Hash}) -> Hash end, NewParts) ++ S#ws.locks,
	S2 = S#ws{
		orig      = NewOrig,
		new       = dict:new(),
		locks     = NewLocks,
		mergerevs = NewMergeRevs},
	case file_store:commit(S#ws.server, S#ws.doc, Object) of
		conflict ->
			{reply, conflict, S2};
		Reply ->
			{stop, normal, Reply, cleanup(S2)};
	end.


do_abort(S) ->
	cleanup(S).


cleanup(#ws{locks=Locks, server=Server} = S) ->
	% unlock hashes
	lists:foreach(fun(Lock) -> file_store:unlock(Server, Lock) end, Locks),
	% delete temporary files
	dict:fold(
		fun (_, {FileName, IODevice}, _) ->
			file:close(IODevice),
			file:delete(FileName)
		end,
		ok,
		S#ws.new),
	% close readers
	dict:fold(
		fun(_Hash, IODevice, _) -> file:close(IODevice) end,
		S#ws.readers),
	S#ws{locks=[], readers=[]}.

