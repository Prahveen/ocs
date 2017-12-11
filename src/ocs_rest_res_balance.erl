%%% ocs_rest_res_balance.erl
%%% vim: ts=3
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @copyright 2016 - 2017 SigScale Global Inc.
%%% @end
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc This library module implements resource handling functions
%%% 	for a REST server in the {@link //ocs. ocs} application.
%%%
-module(ocs_rest_res_balance).
-copyright('Copyright (c) 2016 - 2017 SigScale Global Inc.').

-export([content_types_accepted/0, content_types_provided/0,
		top_up/2, get_balance/1]).

-export([specific_bucket_balance/2]).

-include("ocs.hrl").

%% support deprecated_time_unit()
-define(MILLISECOND, milli_seconds).
%-define(MILLISECOND, millisecond).

-spec content_types_accepted() -> ContentTypes
	when
		ContentTypes :: list().
%% @doc Provides list of resource representations accepted.
content_types_accepted() ->
	["application/json"].

-spec content_types_provided() -> ContentTypes
	when
		ContentTypes :: list().
%% @doc Provides list of resource representations available.
content_types_provided() ->
	["application/json"].

-spec specific_bucket_balance(SubscriberID, BucketID) -> Result
	when
		SubscriberID :: string() | undefined,
		BucketID :: string(),
		Result :: {ok, Headers :: [tuple()], Body :: iolist()}
				| {error, ErrorCode :: integer()}.
%% @doc Body producing function for `GET /balanceManagment/v1/bucket/{id}',
%% `GET /balanceManagment/v1/product/{subscriber_id}/bucket/{id}'
%% reuqests
specific_bucket_balance(SubscriberID, BucketID) ->
	F = fun() ->
		case specific_bucket_balance1(SubscriberID, BucketID) of
			{ok, S, Bucket}->
				{S, Bucket};
			{error, not_found} ->
				throw(not_found)
		end
	end,
	case mnesia:transaction(F) of
		{atomic, {S, B}} ->
			specific_bucket_balance4(S, B);
		{aborted, {throw, not_found}} ->
			{error, 404};
		{aborted, _} ->
			{error, 500}
	end.
%% @hidden
specific_bucket_balance1(undefined, BucketID) ->
	First = mnesia:first(subscriber),
	specific_bucket_balance2(First, BucketID);
specific_bucket_balance1(SubscriberID, BucketID) when is_list(SubscriberID) ->
	specific_bucket_balance1(list_to_binary(SubscriberID), BucketID);
specific_bucket_balance1(SubscriberID, BucketID) when is_binary(SubscriberID) ->
 case specific_bucket_balance3(SubscriberID, BucketID) of
	{#subscriber{} = S, #bucket{} = B} ->
		{ok, S, B};
	{_, false} ->
		{error, not_found};
	{error, Reason} ->
		{error, Reason}
 end.
%% @hidden
specific_bucket_balance2('end_of_table', _BucketID) ->
	{error, not_found};
specific_bucket_balance2(SubscriberID, BucketID) ->
	case specific_bucket_balance3(SubscriberID, BucketID) of
		{#subscriber{} = S, #bucket{} = B} ->
			{ok, S, B};
		{_,  false} ->
			Next = mnesia:next(subscriber, SubscriberID),
			specific_bucket_balance2(Next, BucketID);
		{error, Reason} ->
			{error, Reason}
	end.
%% @hidden
specific_bucket_balance3(SubscriberID, BucketID) ->
	case mnesia:read(subscriber, SubscriberID, read) of
		[#subscriber{buckets = Buckets} = S] ->
			{S, lists:keyfind(BucketID, #bucket.id, Buckets)};
		[] ->
			{error, not_found}
	end.
%% @hidden
specific_bucket_balance4(#subscriber{name = SubID, last_modified = LM}, Bucket) ->
	try
		P_ID = {"id", binary_to_list(SubID)},
		P_Href = {"href", "/productInventory/v1/product/" ++ binary_to_list(SubID)},
		Product = {"product", {struct, [P_ID, P_Href]}},
		{struct, Bucket1} = bucket(Bucket),
		Json = {struct, [Product | Bucket1]},
		Body = mochijson:encode(Json),
		Etag = case LM of
			undefined ->
				[];
			LM ->
				[{etag, ocs_rest:etag(LM)}]
		end,
		Headers = [{content_type, "application/json"}] ++ Etag,
		{ok, Headers, Body}
	catch
		_:_ ->
			{error, 500}
	end.

-spec get_balance(Identity) -> Result
	when
		Identity :: list(),
		Result :: {ok, Headers :: [tuple()], Body :: iolist()}
				| {error, ErrorCode :: integer()}.
%% @doc Body producing function for `GET /balanceManagment/v1/product/{id}/buckets'
%% reuqest
get_balance(Identity) ->
	try
		case ocs:find_subscriber(Identity) of
			{ok, #subscriber{buckets = Buckets, enabled = true}} ->
				get_balance1(Identity, Buckets, "active");
			{ok, #subscriber{buckets = Buckets, enabled = false}} ->
				get_balance1(Identity, Buckets, "disable");
			{error, _Reason} ->
				{error, 500}
		end
	catch
		_Error ->
			{error, 400}
	end.
%% @hidden
get_balance1(Identity, Buckets, ActStatus) ->
	Id = {"id", Identity},
	Href = {"href", "/balanceManagement/v1/buckets/" ++ Identity},
	BucketType = {bucketType, ""},
	Balance = accumulated_balance(Buckets),
	RemAmount = {"remainedAmount", Balance},
	Status = {"status", ActStatus},
	Object = [Id, Href, BucketType, RemAmount, Status],
	Json = {struct, Object},
	Body  = mochijson:encode(Json),
	{ok, [{content_type, "application/json"}], Body}.

-spec top_up(Identity, RequestBody) -> Result
	when
		Identity :: list(),
		RequestBody :: list(),
		Result :: {ok, Headers :: [tuple()], Body :: iolist()}
				| {error, ErrorCode :: integer()}.
%% @doc Respond to `POST /balanceManagement/v1/{id}/balanceTopups'
%% and top up `subscriber' balance resource
top_up(Identity, RequestBody) ->
	try
		{struct, Object} = mochijson:decode(RequestBody),
		{_, _} = lists:keyfind("type", 1, Object),
		{_, {struct, Channel}} = lists:keyfind("channel", 1, Object),
		{_, _} = lists:keyfind("name", 1, Channel),
		{_, {struct, AmountObj}} = lists:keyfind("amount", 1, Object),
		{_, Units} = lists:keyfind("units", 1, AmountObj),
		{_, Amount} = lists:keyfind("amount", 1, AmountObj),
		{StartDate, EndDate} = case lists:keyfind("validFor", 1, Object) of
			{_, {struct, VF}} ->
				SDT = proplists:get_value("startDate", VF),
				EDT = proplists:get_value("endDate", VF),
				case {SDT, EDT} of
					{undefined, undefined} ->
						{undefined, undefined};
					{undefined, EDT} ->
						{undefined, ocs_rest:iso8601(EDT)};
					{SDT, undefined} ->
						{ocs_rest:iso8601(SDT), undefined}
				end;
			false ->
				{undefined, undefined}
		end,
		BucketType = units(Units),
		BID = generate_bucket_id(),
		Bucket = #bucket{id = BID, units = BucketType, remain_amount = Amount,
				start_date = StartDate, termination_date = EndDate},
		top_up1(Identity, Bucket)
	catch
		_Error ->
			{error, 400}
	end.
%% @hidden
top_up1(Identity, Bucket) ->
	F = fun()->
		case mnesia:read(subscriber, list_to_binary(Identity), read) of
			[] ->
				not_found;
			[#subscriber{buckets = CrntBuckets, last_modified = LM} = User] ->
				mnesia:write(User#subscriber{buckets = CrntBuckets ++ [Bucket]}),
				LM
		end
	end,
	case mnesia:transaction(F) of
		{atomic, not_found} ->
			{error, 404};
		{atomic, LastMod} ->
			Location = "/balanceManagement/v1/buckets/" ++ Identity,
			Headers = [{location, Location}, {etag, ocs_rest:etag(LastMod)}],
			{ok, Headers, []};
		{aborted, _Reason} ->
			{error, 500}
	end.


%%----------------------------------------------------------------------
%%  internal functions
%%----------------------------------------------------------------------

-spec accumulated_balance(Buckets) ->	AccumulatedBalance
	when
		Buckets					:: [#bucket{}],
		AccumulatedBalance	:: tuple().
%% @doc return accumulated buckets as a json object.
accumulated_balance([]) ->
	[];
accumulated_balance(Buckets) ->
	accumulated_balance1(Buckets, []).
%% @hidden
accumulated_balance1([], AccBalance) ->
	F = fun({octets, {U1, A1}}, AccIn) ->
				Obj = {struct, [{"amount", A1}, {"units", U1}]},
				[Obj | AccIn];
			({cents, {U2, A2}}, AccIn) ->
				Obj = {struct, [{"amount", A2}, {"units", U2}]},
				[Obj | AccIn];
			({seconds, {U3, A3}}, AccIn) ->
				Obj = {struct, [{"amount", A3}, {"units", U3}]},
				[Obj | AccIn]
	end,
	JsonArray = lists:reverse(lists:foldl(F, [], AccBalance)),
	{array, JsonArray};
accumulated_balance1([Bucket | T], AccBalance) ->
	accumulated_balance1(T, accumulated_balance2(Bucket, AccBalance)).
%% @hidden
accumulated_balance2(#bucket{units = octets, remain_amount = Amount}, AccBalance) ->
	accumulated_balance3(octets, "octets", Amount, AccBalance);
accumulated_balance2(#bucket{units = cents, remain_amount = Amount}, AccBalance) ->
	accumulated_balance3(cents, "cents", Amount, AccBalance);
accumulated_balance2(#bucket{units = seconds, remain_amount = Amount}, AccBalance) ->
	accumulated_balance3(seconds, "seconds", Amount, AccBalance).
%% @hidden
accumulated_balance3(Key, Units, Amount, AccBalance) ->
	case lists:keytake(Key, 1, AccBalance) of
		{value, {Key, {Units, Balance}}, Rest} ->
			[{Key, {Units, Amount + Balance}} | Rest];
		false ->
			[{Key, {Units, Amount}} | AccBalance]
	end.

-spec units(Units) -> Units
	when
		Units :: string() | octets | cents | seconds.
%% @doc Return the type of units of the bucket.
units(Units) when is_list(Units) ->
	units1(string:to_lower(Units));
units(Units) when is_atom(Units) ->
	units1(Units).
%% @hidden
units1("octets") -> octets;
units1("cents") -> cents;
units1("seconds") -> seconds;
units1(octets) -> "octets";
units1(cents) -> "cents";
units1(seconds) -> "seconds".

%% @hidden
generate_bucket_id() ->
	TS = erlang:system_time(?MILLISECOND),
	N = erlang:unique_integer([positive]),
	integer_to_list(TS) ++ "-" ++ integer_to_list(N).

-spec bucket(Bucket) -> Bucket
	when
		Bucket :: #bucket{} | {struct, list()}.
%% @doc CODEC for buckets
bucket(#bucket{} = B) ->
	bucket1(record_info(fields, bucket), B, []);
bucket({struct, Object}) ->
	bucket1(Object, #bucket{}).
%% @hidden
bucket1([{"id", ID} | T], Bucket) ->
	bucket1(T, Bucket#bucket{id = ID});
bucket1([{"name", Name} | T], Bucket) ->
	bucket1(T, Bucket#bucket{name = Name});
bucket1([{"validFor", {struct, L}} | T], Bucket) ->
	Bucket1 = case lists:keyfind("startDateTime", 1, L) of
		{_, Start} ->
			Bucket#bucket{start_date = ocs_rest:iso8601(Start)};
		false ->
			Bucket
	end,
	Bucket2 = case lists:keyfind("endDateTime", 1, L) of
		{_, End} ->
			Bucket1#bucket{termination_date = ocs_rest:iso8601(End)};
		false ->
			Bucket1
	end,
	bucket1(T, Bucket2);
bucket1([{"remain_amount", {struct, L}} | T], Bucket) ->
	Bucket1 = case lists:keyfind("amount", 1, L) of
		{_, Amount} ->
			Bucket#bucket{remain_amount = Amount};
		false ->
			Bucket
	end,
	bucket1(T, Bucket1);
bucket1([_ | T], Bucket) ->
	bucket1(T, Bucket);
bucket1([], Bucket) ->
	Bucket.
%% @hidden
bucket1([id | T], #bucket{id = undefined} = B, Acc) ->
	bucket1(T, B, Acc);
bucket1([id | T], #bucket{id = ID} = B, Acc) ->
	bucket1(T, B, [{"id", ID} | Acc]);
bucket1([name | T], #bucket{name = undefined} = B, Acc) ->
	bucket1(T, B, Acc);
bucket1([name | T], #bucket{name = Name} = B, Acc) ->
	bucket1(T, B, [{"name", Name} | Acc]);
bucket1([remain_amount | T], #bucket{remain_amount = undefined} = B, Acc) ->
	bucket1(T, B, Acc);
bucket1([remain_amount | T], #bucket{remain_amount = RemainAmount} = B, Acc)
		when is_integer(RemainAmount) ->
	RM = {"remainAmount", {struct, [{"amount", RemainAmount}]}},
	bucket1(T, B, [RM | Acc]);
bucket1([start_date | T], #bucket{start_date = undefined,
		termination_date = End} = B, Acc) when is_integer(End) ->
	ValidFor = {struct, [{"endDateTime", ocs_rest:iso8601(End)}]},
	bucket1(T, B, [{"validFor", ValidFor} | Acc]);
bucket1([start_date | T], #bucket{start_date = Start,
		termination_date = undefined} = B, Acc) when is_integer(Start) ->
	ValidFor = {struct, [{"startDateTime", ocs_rest:iso8601(Start)}]},
	bucket1(T, B, [{"validFor", ValidFor} | Acc]);
bucket1([start_date | T], #bucket{start_date = Start,
		termination_date = End} = B, Acc) when is_integer(Start),
		is_integer(End)->
	ValidFor = {struct, [{"endDateTime", ocs_rest:iso8601(End)},
			{"startDateTime", ocs_rest:iso8601(Start)}]},
	bucket1(T, B, [{"validFor", ValidFor} | Acc]);
bucket1([_ | T], B, Acc) ->
	bucket1(T, B, Acc);
bucket1([], _B, Acc) ->
	{struct, Acc}.

