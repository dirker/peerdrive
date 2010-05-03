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

-module(store).

-export([guid/1, contains/2, lookup/2, stat/2]).
-export([put_uuid/4, put_rev_start/3, put_rev_part/3, put_rev_abort/1,
	put_rev_commit/1]).
-export([read_start/3, read_part/4, read_done/1]).
-export([write_start_fork/3, write_start_update/3, write_start_merge/4,
	write_part/4, write_trunc/3, write_abort/1, write_commit/2]).
-export([delete_rev/2, delete_uuid/2]).
-export([sync_get_changes/2, sync_set_anchor/3]).
-export([hash_object/1]).

-include("store.hrl").

%% @doc Get GUID of a store
%% @spec guid(Store::#store) -> guid()
guid(#store{this=Store, guid=Guid}) ->
	Guid(Store).

%% @doc Lookup a UUID.
%%
%% Returns `{ok, Rev}' if the UUID is found on the store, or `error' if no such
%% UUID exists.
%%
%% @spec lookup(Store, Uuid) -> {ok, Rev} | error
%%       Store = #store
%%       Uuid = Rev = guid()
lookup(#store{this=Store, lookup=Lookup}, Uuid) ->
	Lookup(Store, Uuid).

%% @doc Check if a revision exists in the store
%% @spec contains(Store, Rev) -> bool()
%%       Store = #store
%%       Pid = guid()
contains(#store{this=Store, contains=Contains}, Rev) ->
	Contains(Store, Rev).

%% @doc Stat a revision.
%%
%% Returns information about a revision if it is found on the store, or `error'
%% if no such UUID exists.
%%
%% @spec stat(Store, Rev) -> {ok, Flags, Parts, Parents, Mtime, Uti} | error
%%       Store = pid()
%%       Rev = guid()
%%       Parts = [{FourCC::binary(), Size::interger(), Hash::guid()}]
%%       Parents = [guid()]
%%       Mtime = integer()
%%       Uti = binary()
stat(#store{this=Store, stat=Stat}, Rev) ->
	Stat(Store, Rev).

%% @doc Start reading a document revision.
%%
%% Returns the pid of the reader when ready, or an error code. The User argument
%% is the pid of the originally requesting process. The reader process will link
%% to that process.
%%
%% @spec read_start(Store, Rev, User) -> {ok, Reader} | {error, Reason}
%%       Store = #store
%%       User = pid()
%%       Reader = #reader
%%       Rev = guid()
%%       Reason = ecode()
read_start(#store{this=Store, read_start=ReadStart}, Rev, User) ->
	ReadStart(Store, Rev, User).

%% @doc Read a part of a document
%%
%% @spec read_part(Reader, Part, Offset, Length) -> {ok, Data} | eof | {error, Reason}
%%       Reader = #reader
%%       Part = Data = binary()
%%       Offset = Length = integer()
%%       Reason = ecode()
read_part(#reader{this=Reader, read_part=ReadPart}, Part, Offset, Length) ->
	ReadPart(Reader, Part, Offset, Length).

%% @doc Dispose a reader.
%%
%% @spec read_done(Reader::#reader) -> none()
read_done(#reader{this=Reader, done=ReadDone}) ->
	ReadDone(Reader).

%% @doc Create a new document
%%
%% Returns `{ok, Uuid, Writer}' which represents the created UUID and a handle
%% for the following write_* functions to fill the object. The initial revision
%% identifier will be returned by write_done/1 which will always succeed for
%% newly created documents.
%%
%% @spec write_start_fork(Store, StartRev, Uti) -> {ok, Uuid, Writer} | {error, Reason}
%%         Store = #store
%%         Writer = #writer
%%         StartRev, Uuid = guid()
%%         Uti = binary()
%%         Reason = ecode()
write_start_fork(#store{this=Store, write_start_fork=WriteStartFork}, StartRev, Uti) ->
	WriteStartFork(Store, StartRev, Uti).

%% @doc Write to an existing document
%%
%% The new revision will start with the content of the StartRev revision. If
%% Uuid points already to another revision then the call will fail.
%%
%% @spec write_start_update(Store, Uuid, StartRev) -> {ok, Writer} | {error, Reason}
%%        Store = #store
%%        Writer = #writer
%%        Uuid = guid()
%%        StartRevs = guid()
%%        Reason = ecode()
write_start_update(#store{this=Store, write_start_update=WriteStartUpdate}, Uuid, StartRev) ->
	WriteStartUpdate(Store, Uuid, StartRev).

%% @doc Merge a document
%%
%% The new revision of the document will start from scratch and the Uti of the
%% new revision is set according to the Uti parameter. If the Uuid does not
%% point to a revision contained in StartRevs then the call will fail.
%%
%% @spec write_start_merge(Store, Uuid, StartRevs, Uti) -> {ok, Writer} | {error, Reason}
%%        Store = #store
%%        Writer = #writer
%%        Uuid = guid()
%%        StartRevs = [guid()]
%%        Reason = ecode()
%%        Uti = binary()
%%
write_start_merge(#store{this=Store, write_start_merge=WriteStartMerge}, Uuid, StartRevs, Uti) ->
	WriteStartMerge(Store, Uuid, StartRevs, Uti).

% ok | {error, Reason}
write_part(#writer{this=Writer, write_part=WritePart}, Part, Offset, Data) ->
	WritePart(Writer, Part, Offset, Data).

% ok | {error, Reason}
write_trunc(#writer{this=Writer, write_trunc=WriteTrunc}, Part, Offset) ->
	WriteTrunc(Writer, Part, Offset).

% {ok, Rev} | {error, Reason}
write_commit(#writer{this=Writer, commit=Commit}, Mtime) ->
	Commit(Writer, Mtime).

% ok
write_abort(#writer{this=Writer, abort=Abort}) ->
	Abort(Writer).

% ok | {error, Reason}
delete_uuid(#store{this=Store, delete_uuid=DeleteUuid}, Uuid) ->
	DeleteUuid(Store, Uuid).

% ok | {error, Reason}
delete_rev(#store{this=Store, delete_rev=DeleteRev}, Rev) ->
	DeleteRev(Store, Rev).

%% @doc Put/update a UUID in the store
%%
%% Let's a UUID point to a new revision. If the UUID does not exist yet then it
%% is created and points to NewRev. If the UUID exits it must either point
%% OldRev or NewRev, otherwise the call will fail.
%%
%% @spec put_uuid(Store, Uuid, OldRev, NewRev) -> ok | {error, Reason}
%%       Store = #store
%%       Uuid = OldRev = NewRev = guid()
%%       Reason = ecode()
put_uuid(#store{this=Store, put_uuid=PutUuid}, Uuid, OldRev, NewRev) ->
	PutUuid(Store, Uuid, OldRev, NewRev).

%% @doc Put/import a revision into the store.
%%
%% The function takes the specification of the whole revision and returns the
%% list of missing parts which the caller has to supply by subsequent
%% put_rev_part/3 calls. If all parts are already available in the store then
%% the function just returns `ok'.
%%
%% @spec put_rev_start(Store, Rev, Object) -> Result
%%       Store = #store
%%       Rev = guid()
%%       Object = #object
%%       Result = ok | {ok, MissingParts, Importer} | {error, Reason}
%%       MissingParts = [FourCC]
%%       Importer = #importer
%%       Reason = ecode()
put_rev_start(#store{this=Store, put_rev_start=PutRevStart}, Rev, Object) ->
	PutRevStart(Store, Rev, Object).

%% @doc Add data to a revision that's imported
%%
%% @spec put_rev_part(Importer, Part, Data) -> ok | {error, Reason}
%%       Importer = #importer
%%       Part = Data = binary()
%%       Reason = ecode()
put_rev_part(#importer{this=Importer, put_part=PutPart}, Part, Data) ->
	PutPart(Importer, Part, Data).

%% @doc Abort importing a revision
%% @spec put_rev_abort(Importer::#importer) -> none()
put_rev_abort(#importer{this=Importer, abort=Abort}) ->
	Abort(Importer).

%% @doc Finish importing a revision
%% @spec put_rev_commit(Importer::pid()) -> ok | {error, Reason}
%%       Importer = #importer
%%       Reason = ecode()
put_rev_commit(#importer{this=Importer, commit=Commit}) ->
	Commit(Importer).


%% @doc Get changes since the last sync point of peer store
%% @spec sync_get_changes(Store, PeerGuid) ->
%%       Store = #store
%%       PeerGuid = guid()
sync_get_changes(#store{this=Store, sync_get_changes=SyncGetChanges}, PeerGuid) ->
	SyncGetChanges(Store, PeerGuid).


%% @doc Set sync point of peer store to new generation
%% @spec sync_set_anchor(Store, PeerGuid, SeqNum) ->
%%       Store = #store
%%       PeerGuid = guid()
%%       SeqNum = integer()
sync_set_anchor(#store{this=Store, sync_set_anchor=SyncSetAnchor}, PeerGuid, SeqNum) ->
	SyncSetAnchor(Store, PeerGuid, SeqNum).


hash_object(#object{flags=Flags, parts=Parts, parents=Parents, mtime=Mtime, uti=Uti}) ->
	BinParts = lists:foldl(
		fun ({FourCC, Hash}, AccIn) ->
			<<AccIn/binary, FourCC/binary, Hash/binary>>
		end,
		<<(length(Parts)):8>>,
		Parts),
	BinParents = lists:foldl(
		fun (Parent, AccIn) ->
			<<AccIn/binary, Parent/binary>>
		end,
		<<(length(Parents)):8>>,
		Parents),
	BinUti = <<(size(Uti)):32/little, Uti/binary>>,
	erlang:md5(<<Flags:32/little, BinParts/binary, BinParents/binary,
		Mtime:64/little, BinUti/binary>>).
