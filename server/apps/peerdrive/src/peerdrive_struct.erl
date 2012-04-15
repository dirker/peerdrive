%% PeerDrive
%% Copyright (C) 2011  Jan Klötzke <jan DOT kloetzke AT freenet DOT de>
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

-module(peerdrive_struct).
-export([decode/1, encode/1, merge/2]).

-include("utils.hrl").

-define(DICT,   16#00).
-define(LIST,   16#10).
-define(STRING, 16#20).
-define(BOOL,   16#30).
-define(RLINK,  16#40).
-define(DLINK,  16#41).
-define(FLOAT,  16#50).
-define(DOUBLE, 16#51).
-define(UCINT,  16#60).
-define(SCINT,  16#61).
-define(USINT,  16#62).
-define(SSINT,  16#63).
-define(ULINT,  16#64).
-define(SLINT,  16#65).
-define(ULLINT, 16#66).
-define(SLLINT, 16#67).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Decoding
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

decode(Data) ->
	{Term, _} = decode_doc(Data),
	Term.

decode_doc(<<Tag:8, Body/binary>>) ->
	case Tag of
		?DICT   -> decode_dict(Body);
		?LIST   -> decode_list(Body);
		?STRING -> decode_string(Body);
		?BOOL   -> decode_bool(Body);
		?RLINK  -> decode_rlink(Body);
		?DLINK  -> decode_dlink(Body);
		?FLOAT  -> decode_float(Body);
		?DOUBLE -> decode_double(Body);
		?UCINT  -> decode_int(8, false, Body);
		?SCINT  -> decode_int(8, true, Body);
		?USINT  -> decode_int(16, false, Body);
		?SSINT  -> decode_int(16, true, Body);
		?ULINT  -> decode_int(32, false, Body);
		?SLINT  -> decode_int(32, true, Body);
		?ULLINT -> decode_int(64, false, Body);
		?SLLINT -> decode_int(64, true, Body)
	end.


decode_dict(<<Elements:32/little, Body/binary>>) ->
	decode_dict_loop(Elements, gb_trees:empty(), Body).

decode_dict_loop(0, Dict, Rest) ->
	{Dict, Rest};
decode_dict_loop(Count, Dict1, Body1) ->
	{Key, Body2} = decode_string(Body1),
	{Value, Body3} = decode_doc(Body2),
	Dict2 = gb_trees:enter(Key, Value, Dict1),
	decode_dict_loop(Count-1, Dict2, Body3).


decode_list(<<Elements:32/little, Body/binary>>) ->
	decode_list_loop(Elements, [], Body).

decode_list_loop(0, List, Rest) ->
	{lists:reverse(List), Rest};
decode_list_loop(Count, List, Body1) ->
	{Element, Body2} = decode_doc(Body1),
	decode_list_loop(Count-1, [Element|List], Body2).


decode_string(<<StrLen:32/little, Body/binary>>) ->
	<<String:StrLen/binary, Rest/binary>> = Body,
	{binary:copy(String), Rest}.


decode_bool(<<Bool:8, Rest/binary>>) ->
	Value = case Bool of
		0 -> false;
		_ -> true
	end,
	{Value, Rest}.


decode_rlink(<<Size:8, Rev:Size/binary, Rest/binary>>) ->
	{{rlink, binary:copy(Rev)}, Rest}.


decode_dlink(<<Size:8, Doc:Size/binary, Rest/binary>>) ->
	{{dlink, binary:copy(Doc)}, Rest}.


decode_float(<<Value:32/little-float, Rest/binary>>) ->
	{Value, Rest}.


decode_double(<<Value:64/little-float, Rest/binary>>) ->
	{Value, Rest}.


decode_int(Size, Signed, Body) ->
	case Signed of
		true ->
			<<Value:Size/little-signed, Rest/binary>> = Body,
			{Value, Rest};
		false ->
			<<Value:Size/little-unsigned, Rest/binary>> = Body,
			{Value, Rest}
	end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Encoding
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

encode(Dict) when ?IS_GB_TREE(Dict) ->
	lists:foldl(
		fun({Key, Value}, Acc) when is_binary(Key) ->
			EncKey = <<(size(Key)):32/little, Key/binary>>,
			EncVal = encode(Value),
			<<Acc/binary, EncKey/binary, EncVal/binary>>
		end,
		<<?DICT, (gb_trees:size(Dict)):32/little>>,
		gb_trees:to_list(Dict));

encode(List) when is_list(List) ->
	lists:foldl(
		fun(Element, Acc) ->
			EncElem = encode(Element),
			<<Acc/binary, EncElem/binary>>
		end,
		<<?LIST, (length(List)):32/little>>,
		List);

encode(String) when is_binary(String) ->
	<<?STRING, (size(String)):32/little, String/binary>>;

encode(Bool) when is_boolean(Bool) ->
	case Bool of
		true  -> <<?BOOL, 1>>;
		false -> <<?BOOL, 0>>
	end;

encode({rlink, Rev}) ->
	<<?RLINK, (size(Rev)):8, Rev/binary>>;

encode({dlink, Doc}) ->
	<<?DLINK, (size(Doc)):8, Doc/binary>>;

encode(Float) when is_float(Float) ->
	<<?DOUBLE, Float:64/little-float>>;

encode(Int) when is_integer(Int) ->
	if
		Int < 0 ->
			if
				Int >= -128        -> <<?SCINT,  Int:8/signed-little>>;
				Int >= -32768      -> <<?SSINT,  Int:16/signed-little>>;
				Int >= -2147483648 -> <<?SLINT,  Int:32/signed-little>>;
				true               -> <<?SLLINT, Int:64/signed-little>>
			end;

		true ->
			if
				Int =< 16#ff       -> <<?UCINT,  Int:8/unsigned-little>>;
				Int =< 16#ffff     -> <<?USINT,  Int:16/unsigned-little>>;
				Int =< 16#ffffffff -> <<?ULINT,  Int:32/unsigned-little>>;
				true               -> <<?ULLINT, Int:64/unsigned-little>>
			end
	end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Merging
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

merge(Base, Versions) ->
	case check_type(Base, Versions) of
		econflict -> {econflict, hd(Versions)};
		dict      -> merge_dict(Base, Versions);
		list      -> merge_list(Base, Versions);
		literal   -> merge_literal(Base, Versions)
	end.


%%
%% Dicts are merged based on keys. For common keys the merge descends.
%%
merge_dict(Base, Versions) ->
	% compute the differences
	BaseKeys = sets:from_list(gb_trees:keys(Base)),
	{Res, Added, Removed} = lists:foldl(
		fun(Dict, {AccRes, AccAdd, AccRem}) ->
			VerKeys = sets:from_list(gb_trees:keys(Dict)),
			% check for added keys
			{NewRes, NewAdd} = sets:fold(
				fun(Key, {InRes, InAdd}) ->
					VerValue = gb_trees:get(Key, Dict),
					case gb_trees:is_defined(Key, InAdd) of
						true ->
							% already added by another version; conflicting?
							case cmp(VerValue, gb_trees:get(Key, InAdd)) of
								true  -> {InRes, InAdd};
								false -> {econflict, InAdd}
							end;

						false ->
							% this one is new
							{InRes, gb_trees:enter(Key, VerValue, InAdd)}
					end
				end,
				{AccRes, AccAdd},
				sets:subtract(VerKeys, BaseKeys)),
			% check for removed keys
			NewRem = sets:union(AccRem, sets:subtract(BaseKeys, VerKeys)),
			{NewRes, NewAdd, NewRem}
		end,
		{ok, gb_trees:empty(), sets:new()},
		Versions),
	% construct new dict
	{Res1, NewDict1} = lists:foldl(
		fun({Key, BaseValue}, {AccRes, AccDict}) ->
			OtherValues = [gb_trees:get(Key, V) || V <- Versions, gb_trees:is_defined(Key, V)],
			case sets:is_element(Key, Removed) of
				true ->
					% has been deleted; is there modify/delete conflict?
					Conflict = lists:any(
						fun(VerVal) -> not cmp(BaseValue, VerVal) end,
						OtherValues),
					case Conflict of
						true ->
							% yes :( -> take the latest version
							Latest = hd(Versions),
							case gb_trees:is_defined(Key, Latest) of
								true ->
									% the latest version still has it.. retain
									{_, NewVal} = merge(BaseValue, OtherValues),
									{econflict, gb_trees:enter(Key, NewVal, AccDict)};

								false ->
									% the latest version deleted it.. bye bye
									{econflict, AccDict}
							end;

						false ->
							% only deleted, nobody modified it
							{AccRes, AccDict}
					end;

				false ->
					% not deleted, descent merging
					{Conflict, NewVal} = merge(BaseValue, OtherValues),
					case AccRes of
						ok -> {Conflict, gb_trees:enter(Key, NewVal, AccDict)};
						_  -> {AccRes, gb_trees:enter(Key, NewVal, AccDict)}
					end
			end
		end,
		{Res, gb_trees:empty()},
		gb_trees:to_list(Base)),
	% Store the added keys
	NewDict2 = lists:foldl(
		fun({Key, AddValue}, AccDict) ->
			gb_trees:enter(Key, AddValue, AccDict)
		end,
		NewDict1,
		gb_trees:to_list(Added)),
	{Res1, NewDict2}.


%%
%% Lists are treated as kind of sets. The merge result is just the unification
%% of all Versions. In contrast to sets duplicates are not removed though.
%%
merge_list(_Base, [FirstVer | OtherVers]) ->
	NewList = lists:foldl(
		fun(Ver, Acc) ->
			Added = [X || X <- Ver, not lists:any(fun(E) -> cmp(X, E) end, Acc)],
			Acc ++ Added
		end,
		FirstVer,
		OtherVers),
	{ok, NewList}.



%%
%% Literals merging is simple. At most one change is allowed compared to Base.
%% If there are more changes a conflict is flagged and the first changed
%% version is taken.
%%
merge_literal(Base, Versions) ->
	Changes = [X || X <- Versions, not cmp(Base, X)],
	Unique = lists:foldl(
		fun(Change, Acc) ->
			case lists:any(fun(E) -> cmp(Change, E) end, Acc) of
				true  -> Acc;
				false -> [Change | Acc]
			end
		end,
		[],
		Changes),
	case length(Unique) of
		0 -> {ok, Base};
		1 -> {ok, hd(Changes)};
		_ -> {econflict, hd(Changes)}
	end.


%%
%% Comparing is unfortunately a bit more involved because gb_trees cannot be
%% compared literally.
%%
cmp(X1, X2) when
		is_integer(X1) or
		is_float(X1) or
		is_boolean(X1) or
		is_binary(X1) ->
	X1 =:= X2;

cmp(X1, X2) when is_list(X1) ->
	cmp_list(X1, X2);

cmp({rlink, R1}, {rlink, R2}) ->
	R1 =:= R2;

cmp({dlink, Doc1}, {dlink, Doc2}) ->
	Doc1 =:= Doc2;

cmp(X1, X2) ->
	cmp_dict(gb_trees:to_list(X1), gb_trees:to_list(X2)).


cmp_list([V1|Rest1], [V2|Rest2]) ->
	cmp(V1, V2) andalso cmp_list(Rest1, Rest2);

cmp_list([], []) ->
	true;

cmp_list(_, _) ->
	false.


cmp_dict([{K1,V1}|Rest1], [{K2,V2}|Rest2]) ->
	K1 == K2 andalso cmp(V1, V2) andalso cmp_dict(Rest1, Rest2);

cmp_dict([], []) ->
	true;

cmp_dict(_, _) ->
	false.


%%
%% Check if all types match
%%
check_type(Base, Versions) when is_integer(Base) ->
	case lists:all(fun is_integer/1, Versions) of
		true  -> literal;
		false -> econflict
	end;

check_type(Base, Versions) when is_float(Base) ->
	case lists:all(fun is_float/1, Versions) of
		true  -> literal;
		false -> econflict
	end;

check_type(Base, Versions) when is_boolean(Base) ->
	case lists:all(fun is_boolean/1, Versions) of
		true  -> literal;
		false -> econflict
	end;

check_type(Base, Versions) when is_binary(Base) ->
	case lists:all(fun is_binary/1, Versions) of
		true  -> literal;
		false -> econflict
	end;

check_type(Base, Versions) when is_list(Base) ->
	case lists:all(fun is_list/1, Versions) of
		true  -> list;
		false -> econflict
	end;

check_type(Base, Versions) when ?IS_GB_TREE(Base) ->
	case lists:all(fun(V) -> ?IS_GB_TREE(V) end, Versions) of
		true  -> dict;
		false -> econflict
	end;

check_type(Base, Versions) when is_record(Base, rlink, 2) ->
	case lists:all(fun(V) -> is_record(V, rlink, 2) end, Versions) of
		true  -> literal;
		false -> econflict
	end;

check_type(Base, Versions) when is_record(Base, dlink, 2) ->
	case lists:all(fun(V) -> is_record(V, dlink, 2) end, Versions) of
		true  -> literal;
		false -> econflict
	end;

check_type(_, _) ->
	econflict.

