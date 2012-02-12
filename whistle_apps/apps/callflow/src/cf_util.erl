-module(cf_util).

-include("callflow.hrl").

-export([presence_probe/2]).
-export([update_mwi/2, update_mwi/4]).
-export([get_prompt/1, get_prompt/2]).
-export([alpha_to_dialpad/1, ignore_early_media/1]).
-export([correct_media_path/2]).
-export([call_to_proplist/1]).
-export([lookup_callflow/1, lookup_callflow/2]).
-export([handle_bridge_failure/2, handle_bridge_failure/3]).
-export([send_default_response/2]).
-export([get_sip_realm/2, get_sip_realm/3]).

-define(PROMPTS_CONFIG_CAT, <<(?CF_CONFIG_CAT)/binary, ".prompts">>).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec presence_probe/2 :: (wh_json:json_object(), proplist()) -> ok.
presence_probe(JObj, _Props) ->
    ToUser = wh_json:get_value(<<"To-User">>, JObj),
    ToRealm = wh_json:get_value(<<"To-Realm">>, JObj),
    FromUser = wh_json:get_value(<<"From-User">>, JObj),
    FromRealm = wh_json:get_value(<<"From-Realm">>, JObj),
    Subscription = wh_json:get_value(<<"Subscription">>, JObj),
    ProbeRepliers = [fun presence_mwi_update/4
                     ,fun presence_parking_slot/4
                    ],
    [Fun(Subscription, {FromUser, FromRealm}, {ToUser, ToRealm}, JObj) || Fun <- ProbeRepliers],
    ok.

-spec presence_mwi_update/4 :: (ne_binary(), {ne_binary(), ne_binary()}, {ne_binary(), ne_binary()}, wh_json:json_object()) -> ok.
presence_mwi_update(<<"message-summary">>, {FromUser, FromRealm}, _, _) ->     
    case whapps_util:get_account_by_realm(FromRealm) of
        {ok, AccountDb} ->
            ViewOptions = [{<<"include_docs">>, true}
                           ,{<<"key">>, FromUser}
                          ],
            case couch_mgr:get_results(AccountDb, <<"cf_attributes/sip_credentials">>, ViewOptions) of
                {ok, []} -> 
                    ?LOG("sip credentials not in account db ~s", [AccountDb]),
                    ok;
                {ok, [Device]} -> 
                    update_mwi(wh_json:get_value([<<"doc">>, <<"owner_id">>], Device), AccountDb);
                {error, _R} -> 
                    ?LOG("unable to lookup sip credentials for owner id: ~p", [_R]),
                    ok
            end;
        _E ->
            ?LOG("failed to find the account for realm ~s: ~p", [FromRealm, _E]),
            ok
    end;
presence_mwi_update(_, _, _, _) ->
    ok.

-spec presence_parking_slot/4 :: (ne_binary(), {ne_binary(), ne_binary()}, {ne_binary(), ne_binary()}, wh_json:json_object()) -> ok.
presence_parking_slot(_, _, _, _) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec update_mwi/2 :: (undefined | ne_binary(), ne_binary()) -> ok.
-spec update_mwi/4 :: (non_neg_integer() | ne_binary(), non_neg_integer() | ne_binary(), ne_binary(), ne_binary()) -> ok.

update_mwi(undefined, _) ->
    ok;
update_mwi(OwnerId, AccountDb) ->
    ViewOptions = [{<<"reduce">>, true}
                   ,{<<"group">>, true}
                   ,{<<"startkey">>, [OwnerId]}
                   ,{<<"endkey">>, [OwnerId, "\ufff0"]}
                  ],    
    case couch_mgr:get_results(AccountDb, <<"cf_attributes/vm_count_by_owner">>, ViewOptions) of
        {ok, MessageCounts} -> 
            Props = [{wh_json:get_value([<<"key">>, 2], MessageCount), wh_json:get_value(<<"value">>, MessageCount)}
                     || MessageCount <- MessageCounts
                    ],
            update_mwi(props:get_value(<<"new">>, Props, 0), props:get_value(<<"saved">>, Props, 0), OwnerId, AccountDb);
        {error, _R} ->
            ?LOG("unable to lookup vm counts by owner: ~p", [_R]),
            ok
    end.

update_mwi(New, Saved, OwnerId, AccountDb) ->
    AccountId = wh_util:format_account_id(AccountDb, raw),
    ViewOptions = [{<<"key">>, [OwnerId, <<"device">>]}
                   ,{<<"include_docs">>, true}
                  ],    
    case couch_mgr:get_results(AccountDb, <<"cf_attributes/owned">>, ViewOptions) of
        {ok, Devices} -> 
            ?LOG("updating MWI for owner ~s: (~b/~b) on ~b devices", [OwnerId, New, Saved, length(Devices)]),
            CommonHeaders = [{<<"Messages-New">>, New}
                             ,{<<"Messages-Saved">>, Saved}
                             | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
                            ],
            lists:foreach(fun(Result) ->
                                  Device = wh_json:get_value(<<"doc">>, Result, wh_json:new()),
                                  User = wh_json:get_value([<<"sip">>, <<"username">>], Device),
                                  Realm = cf_util:get_sip_realm(Device, AccountId),
                                  Command = wh_json:from_list([{<<"Notify-User">>, User}
                                                               ,{<<"Notify-Realm">>, Realm}
                                                               | CommonHeaders
                                                              ]),
                                  catch (wapi_notifications:publish_mwi_update(Command))
                          end, Devices),
            ok;
        {error, _R} ->
            ?LOG("failed to find devices owned by ~s: ~p", [OwnerId, _R]),
            ok
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec alpha_to_dialpad/1 :: (ne_binary()) -> ne_binary().
alpha_to_dialpad(Value) ->
    << <<(dialpad_digit(C))>> || <<C>> <= strip_nonalpha(wh_util:to_lower_binary(Value))>>.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec strip_nonalpha/1 :: (ne_binary()) -> ne_binary().
strip_nonalpha(Value) ->
    re:replace(Value, <<"[^[:alpha:]]">>, <<>>, [{return,binary}, global]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec dialpad_digit/1 :: (Char) -> 50..57 when
      Char :: 97..122.
dialpad_digit(ABC) when ABC =:= $a orelse ABC =:= $b orelse ABC =:= $c -> $2;
dialpad_digit(DEF) when DEF =:= $d orelse DEF =:= $e orelse DEF =:= $f -> $3;
dialpad_digit(GHI) when GHI =:= $g orelse GHI =:= $h orelse GHI =:= $i -> $4;
dialpad_digit(JKL) when JKL =:= $j orelse JKL =:= $k orelse JKL =:= $l -> $5;
dialpad_digit(MNO) when MNO =:= $m orelse MNO =:= $n orelse MNO =:= $o -> $6;
dialpad_digit(PQRS) when PQRS =:= $p orelse PQRS =:= $q orelse PQRS =:= $r orelse PQRS =:= $s -> $7;
dialpad_digit(TUV) when TUV =:= $t orelse TUV =:= $u orelse TUV =:= $v -> $8;
dialpad_digit(WXYZ) when WXYZ =:= $w orelse WXYZ =:= $x orelse WXYZ =:= $y orelse WXYZ =:= $z -> $9.

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec get_prompt/1 :: (ne_binary()) -> ne_binary().
-spec get_prompt/2 :: (ne_binary(), ne_binary()) -> ne_binary().

get_prompt(Name) ->
    get_prompt(Name, <<"en">>).

get_prompt(Name, Lang) ->
    whapps_config:get(?PROMPTS_CONFIG_CAT, [Lang, Name], <<"/system_media/", Name/binary>>).    

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Determine if we should ignore early media
%% @end
%%--------------------------------------------------------------------
-spec ignore_early_media/1 :: (wh_json:json_objects()) -> ne_binary().
ignore_early_media(Endpoints) ->
    Ignore = lists:foldr(fun(Endpoint, Acc) ->
                                 wh_json:is_true(<<"Ignore-Early-Media">>, Endpoint)
                                     or Acc
                         end, false, Endpoints),
    wh_util:to_binary(Ignore).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% given a media path that is just a media id correct it to include
%% the account id
%% @end
%%--------------------------------------------------------------------
-spec correct_media_path/2 :: ('undefined' | ne_binary(), #cf_call{}) -> 'undefined' | ne_binary().
correct_media_path(undefined, _) ->
    undefined;
correct_media_path(<<"silence_stream://", _/binary>> = Media, _) ->
    Media;
correct_media_path(<<"tone_stream://", _/binary>> = Media, _) ->
    Media;
correct_media_path(Media, #cf_call{account_id=AccountId}) ->
    case binary:match(Media, <<"/">>) of
        nomatch ->
            <<$/, AccountId/binary, $/, Media/binary>>;
        _Else ->
            Media
    end.

%%-----------------------------------------------------------------------------
%% @public
%% @doc
%% Convert the call record to a proplist
%% @end
%%-----------------------------------------------------------------------------
-spec call_to_proplist/1 :: (#cf_call{}) -> proplist().
call_to_proplist(#cf_call{} = Call) ->
    [{wh_util:to_binary(K), V}
     || {K, V} <- lists:zip(record_info(fields, cf_call), tl(tuple_to_list(Call)))
            ,K =/= cf_pid andalso K =/= call_kvs
    ].

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%% lookup the callflow based on the requested number in the account
%% @end
%%-----------------------------------------------------------------------------
-spec lookup_callflow/1 :: (#cf_call{}) -> {'ok', wh_json:json_object(), boolean()} | {'error', term()}.
-spec lookup_callflow/2 :: (ne_binary(), ne_binary()) -> {'ok', wh_json:json_object(), boolean()} | {'error', term()}.

lookup_callflow(#cf_call{request_user=Number, account_id=AccountId}) ->
    lookup_callflow(Number, AccountId).

lookup_callflow(Number, AccountId) ->
    case wh_util:is_empty(Number) of
        true -> {error, invalid_number};
        false ->
            Db = wh_util:format_account_id(AccountId, encoded),
            do_lookup_callflow(wh_util:to_binary(Number), Db)
    end.

do_lookup_callflow(Number, Db) ->
    ?LOG("searching for callflow in ~s to satisfy '~s'", [Db, Number]),
%%    case wh_cache:fetch({cf_flow, Number, Db}) of
%%      {ok, Flow} ->
%%          {ok, Flow, Number =:= ?NO_MATCH_CF};
%%      {error, not_found} ->
            Options = [{<<"key">>, Number}, {<<"include_docs">>, true}],
            case couch_mgr:get_results(Db, ?LIST_BY_NUMBER, Options) of
                {ok, []} when Number =/= ?NO_MATCH_CF ->
                    case lookup_callflow_patterns(Number, Db) of
                        {error, _} ->
                            do_lookup_callflow(?NO_MATCH_CF, Db);
                        {ok, {Flow, Capture}} ->
                            F = wh_json:set_value(<<"capture_group">>, Capture, Flow),
                            wh_cache:store({cf_flow, Number, Db}, F),
                            {ok, F, false}
                    end;
                {ok, []} ->
                    {error, not_found};
                {ok, [{struct, _}=JObj]} ->
                    Flow = wh_json:get_value(<<"doc">>, JObj),
                    wh_cache:store({cf_flow, Number, Db}, Flow),
                    {ok, Flow, Number =:= ?NO_MATCH_CF};
                {ok, [{struct, _}=JObj | _Rest]} ->
                    ?LOG("lookup resulted in more than one result, using the first"),
                    Flow = wh_json:get_value(<<"doc">>, JObj),
                    wh_cache:store({cf_flow, Number, Db}, Flow),
                    {ok, Flow, Number =:= ?NO_MATCH_CF};
                {error, _}=E ->
                    E
            end.
%%    end.

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%% send a route response for a route request that can be fulfilled by this
%% process
%% @end
%%-----------------------------------------------------------------------------
-spec lookup_callflow_patterns/2 :: (ne_binary(), ne_binary())
                                    -> {'ok', {wh_json:json_object(), ne_binary()}} | {'error', term()}.
lookup_callflow_patterns(Number, Db) ->
    ?LOG("lookup callflow patterns for ~s in ~s", [Number, Db]),
    case couch_mgr:get_results(Db, ?LIST_BY_PATTERN, [{<<"include_docs">>, true}]) of
        {ok, Patterns} ->
            case test_callflow_patterns(Patterns, Number, {undefined, <<>>}) of
                {undefined, <<>>} -> {error, not_found};
                {Flow, <<>>} -> {ok, {Flow, undefined}};
                Match -> {ok, Match}
            end;
        {error, _}=E ->
            E
    end.

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%-----------------------------------------------------------------------------
-spec test_callflow_patterns/3 :: (wh_json:json_objects(), ne_binary()
                                   ,{'undefined', <<>>} | {wh_json:json_object(), ne_binary()})
                                  -> {'undefined', <<>>} | {wh_json:json_object(), ne_binary()}.
test_callflow_patterns([], _, Result) ->
    Result;
test_callflow_patterns([Pattern|T], Number, {_, Capture}=Result) ->
    Regex = wh_json:get_value(<<"key">>, Pattern),
    case re:run(Number, Regex) of
        {match, [{Start,End}]} ->
            Match = binary:part(Number, Start, End),
            Flow = wh_json:get_value(<<"doc">>, Pattern),
            case binary:part(Number, Start, End) of
                <<>> when Capture =:= <<>> ->
                    test_callflow_patterns(T, Number, {Flow, <<>>});
                Match when size(Match) > size(Capture); size(Match) =:= 0 ->
                    test_callflow_patterns(T, Number, {Flow, Match});
                _ ->
                    test_callflow_patterns(T, Number, Result)
            end;
        {match, CaptureGroups} ->
            %% find the largest matching group if present by sorting the position of the
            %% matching groups by list, reverse so head is largest, then take the head of the list
            {Start, End} = hd(lists:reverse(lists:keysort(2, tl(CaptureGroups)))),
            Flow = wh_json:get_value(<<"doc">>, Pattern),
            case binary:part(Number, Start, End) of
                <<>> when Capture =:= <<>> ->
                    test_callflow_patterns(T, Number, {Flow, <<>>});
                Match when size(Match) > size(Capture) ->
                    test_callflow_patterns(T, Number, {Flow, Match});
                _ ->
                    test_callflow_patterns(T, Number, Result)
            end;
        _ ->
            test_callflow_patterns(T, Number, Result)
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Look for children branches to handle the failure replies of
%% certain actions, like cf_offnet and cf_resources
%% @end
%%--------------------------------------------------------------------
-spec handle_bridge_failure/2 :: ({'fail', wh_json:json_object()} | ne_binary() | 'undefined', #cf_call{}) -> 'ok' | 'not_found'.
-spec handle_bridge_failure/3 :: (ne_binary() | 'undefined', ne_binary() | 'undefined', #cf_call{}) -> 'ok' | 'not_found'.

handle_bridge_failure({fail, Reason}, Call) ->
    {Cause, Code} = whapps_util:get_call_termination_reason(Reason),
    handle_bridge_failure(Cause, Code, Call);
handle_bridge_failure(undefined, _) ->
    not_found;
handle_bridge_failure(Failure, Call) ->
    case cf_exe:attempt(Failure, Call) of
        {attempt_resp, ok} ->
            ?LOG("found child branch to handle failure: ~s", [Failure]),
            ok;
        {attempt_resp, _} ->
            not_found
    end.

handle_bridge_failure(Cause, Code, Call) ->
    ?LOG("attempting to find failure branch for ~s:~s", [Code, Cause]),
    case (handle_bridge_failure(Cause, Call) =:= ok)
        orelse (handle_bridge_failure(Code, Call) =:= ok) of
        true -> ok;
        false ->
            cf_exe:continue(Call),
            not_found
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Send and wait for a call failure cause response
%% @end
%%--------------------------------------------------------------------
-spec send_default_response/2 :: (ne_binary(), #cf_call{}) -> ok.
send_default_response(Cause, Call) ->
    CallId = cf_exe:callid(Call),
    CtrlQ = cf_exe:control_queue_name(Call),
    case wh_call_response:send_default(CallId, CtrlQ, Cause) of
        {error, no_response} -> ok;
        {ok, NoopId} -> cf_call_command:wait_for_noop(NoopId)
    end,
    ok.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Get the sip realm
%% @end
%%--------------------------------------------------------------------
-spec get_sip_realm/2 :: (wh_json:json_object(), ne_binary()) -> 'undefined' | ne_binary().
-spec get_sip_realm/3 :: (wh_json:json_object(), ne_binary(), Default) -> Default | ne_binary().

get_sip_realm(SIPJObj, AccountId) ->
    get_sip_realm(SIPJObj, AccountId, undefined).

get_sip_realm(SIPJObj, AccountId, Default) ->
    case wh_json:get_ne_value([<<"sip">>, <<"realm">>], SIPJObj) of
        undefined -> 
            case wh_util:get_account_realm(AccountId) of
                undefined -> Default;
                Else -> Else
            end;
        Realm -> Realm
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

alpha_to_dialpad_test() ->
    ?assertEqual(<<"222">>, alpha_to_dialpad(<<"abc">>)),
    ?assertEqual(<<"23456789">>, alpha_to_dialpad(<<"behknqux">>)),
    ?assertEqual(<<"23456789">>, alpha_to_dialpad(<<"BeHkNqUx">>)),
    ?assertEqual(<<"23456789">>, alpha_to_dialpad(<<"1BeH@k(N$q-u+x=">>)).

-endif.
