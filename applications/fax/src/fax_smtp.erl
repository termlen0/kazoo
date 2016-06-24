%%%-------------------------------------------------------------------
%%% @copyright (C) 2014-2016, 2600Hz INC
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   Luis Azedo
%%%-------------------------------------------------------------------

-module(fax_smtp).
-behaviour(gen_smtp_server_session).

-export([init/4
         ,handle_HELO/2
         ,handle_EHLO/3
         ,handle_MAIL/2
         ,handle_MAIL_extension/2
         ,handle_RCPT/2
         ,handle_RCPT_extension/2
         ,handle_DATA/4
         ,handle_RSET/1
         ,handle_VRFY/2
         ,handle_other/3
         ,handle_AUTH/4
         ,handle_STARTTLS/1
         ,code_change/3
         ,terminate/2
        ]).

-include("fax.hrl").

-define(RELAY, 'true').
-define(SMTP_MAX_SESSIONS, kapps_config:get_integer(?CONFIG_CAT, <<"smtp_sessions">>, 50)).
-define(DEFAULT_IMAGE_SIZE_CMD_FMT, <<"echo -n `identify -format \"%[fx:w]x%[fx:h]\" ~s`">>).
-define(IMAGE_SIZE_CMD_FMT, kapps_config:get_binary(?CONFIG_CAT, <<"image_size_cmd_format">>, ?DEFAULT_IMAGE_SIZE_CMD_FMT)).

-record(state, {
          options = [] :: list()
          ,from :: binary()
          ,to :: binary()
          ,doc :: api_object()
          ,filename :: api_binary()
          ,content_type :: binary()
          ,peer_ip :: peer()
          ,owner_id :: api_binary()
          ,owner_email :: api_binary()
          ,faxbox_email :: api_binary()
          ,faxbox :: api_object()
          ,errors = [] :: ne_binaries()
          ,original_number :: api_binary()
          ,number :: api_binary()
          ,account_id :: api_binary()
          ,session_id :: api_binary()
          ,proxy :: api_binary()
         }).

-type state() :: #state{}.
-type error_message() :: {'error', string(), #state{}}.

-type peer() :: {inet:ip_address(), non_neg_integer()}.

-spec init(ne_binary(), non_neg_integer(), peer(), kz_proplist()) ->
                  {'ok', string(), #state{}} |
                  {'stop', _, string()}.
init(Hostname, SessionCount, Address, Options) ->
    case SessionCount > ?SMTP_MAX_SESSIONS  of
        'false' ->
            Banner = [Hostname, " Kazoo Email to Fax Server"],
            State = #state{options = Options
                           ,peer_ip = Address
                           ,session_id = kz_util:rand_hex_binary(16)
                          },
            kz_util:put_callid(State#state.session_id),
            {'ok', Banner, State};
        'true' ->
            lager:warning("connection limit exceeded ~p", [Address]),
            {'stop', 'normal', ["421 ", Hostname, " is too busy to accept mail right now"]}
    end.

-spec handle_HELO(binary(), state()) ->
                         {'ok', pos_integer(), state()} |
                         {'ok', state()} |
                         error_message().
handle_HELO(Hostname, State) ->
   lager:debug("HELO from ~s, max message size is ~B", [Hostname, ?SMTP_MSG_MAX_SIZE]),
   {'ok', ?SMTP_MSG_MAX_SIZE, State}.

-spec handle_EHLO(binary(), list(), state()) ->
                         {'ok', list(), state()} |
                         error_message().
handle_EHLO(Hostname, Extensions, #state{options=Options, proxy = Proxy}=State) ->
    lager:debug("EHLO from ~s with proxy ~s", [Hostname, Proxy]),
    %% You can advertise additional extensions, or remove some defaults
    MyExtensions = case props:get_is_true('auth', Options, 'false') of
                       'false' -> Extensions;
                       'true' ->
                           %% auth is enabled, so advertise it
                           [{"AUTH", "PLAIN LOGIN CRAM-MD5"}
                            ,{"STARTTLS", 'true'}
                            | Extensions
                           ]
                   end,
    {'ok', filter_extensions(MyExtensions, Options), State}.

-spec filter_extensions(kz_proplist(), kz_proplist()) -> kz_proplist().
filter_extensions(BuilIn, Options) ->
   Extensions = props:get_value('extensions', Options, ?SMTP_EXTENSIONS),
   lists:filter(fun({N,_}) -> not props:is_defined(N, Extensions) end, BuilIn) ++ Extensions.

-spec handle_MAIL(binary(), state()) -> {'ok', state()}.
handle_MAIL(FromHeader, State) ->
    From = kz_util:to_lower_binary(FromHeader),
    lager:debug("Checking Mail from ~s", [From]),
    {'ok', State#state{from=From}}.

-spec handle_MAIL_extension(binary(), state()) ->
                                   'error'.
handle_MAIL_extension(Extension, _State) ->
    Error = kz_util:to_binary(io_lib:format("554 Unknown MAIL FROM extension ~s", [Extension])),
    lager:debug(Error),
    'error'.

-spec handle_RCPT(binary(), state()) ->
                         {'ok', state()} |
                         {'error', string(), state()}.
handle_RCPT(ToHeader, State) ->
    To = kz_util:to_lower_binary(ToHeader),
    lager:debug("Checking Mail to ~s", [To]),
    check_faxbox((reset(State))#state{to=To}).

-spec handle_RCPT_extension(binary(), state()) ->
                                   'error'.
handle_RCPT_extension(Extension, _State) ->
    Error = kz_util:to_binary(io_lib:format("554 Unknown RCPT TO extension ~s", [Extension])),
    lager:debug(Error),
    'error'.

-spec handle_DATA(binary(), ne_binaries(), binary(), state()) ->
                         {'ok', string(), state()} |
                         {'error', string(), state()}.
handle_DATA(From, To, <<>>, State) ->
    lager:debug("552 Message too small. From ~p to ~p", [From,To]),
    {'error', "552 Message too small", State};
handle_DATA(From, To, Data, #state{options=Options}=State) ->
    lager:debug("Handle Data From ~p to ~p", [From,To]),

    %% JMA: Can this be done with kz_util:rand_hex_binary() ?
    Reference = lists:flatten(
                  [io_lib:format("~2.16.0b", [X])
                   || <<X>> <= erlang:md5(term_to_binary(kz_util:now()))
                  ]),

    try mimemail:decode(Data) of
        {Type, SubType, Headers, Parameters, Body} ->
            lager:debug("Message decoded successfully!"),
            case process_message(Type, SubType, Headers, Parameters, Body, State) of
                {ProcessResult, #state{errors=[]}=NewState} ->
                    {ProcessResult, Reference, NewState};
                {ProcessResult, #state{errors=[Error | _]}=NewState} ->
                    {ProcessResult, <<"554 ",Error/binary>>, NewState}
            end
    catch
        _What:_Why ->
            lager:debug("Message decode FAILED with ~p:~p", [_What, _Why]),
            handle_DATA_exception(Options, Reference, Data),
            {'error', "554 Message decode failed", State#state{errors=[<<"Message decode failed">>]}}
    end.

-spec handle_DATA_exception(kz_proplist(), list(), binary()) -> 'ok'.
handle_DATA_exception(Options, Reference, Data) ->
    case props:get_is_true('dump', Options, 'false') of
        'false' -> 'ok';
        'true' ->
            %% optionally dump the failed email somewhere for analysis
            File = "/tmp/"++Reference,
            case filelib:ensure_dir(File) of
                'ok' -> kz_util:write_file(File, Data);
                _ -> 'ok'
            end
    end.

-spec handle_RSET(state()) -> state().
handle_RSET(State) ->
    lager:debug("RSET Called"),
    %% reset any relevant internal state
    State.

-spec handle_VRFY(binary(), state()) ->
                         {'error', string(), state()}.
handle_VRFY(_Address, State) ->
    lager:debug("252 VRFY disabled by policy, just send some mail"),
    {'error', "252 VRFY disabled by policy, just send some mail", State}.

-spec handle_other(binary(), binary(), state()) ->
                          {iolist() | 'noreply', state()}.
handle_other(<<"PROXY">>, Args, State) ->
    {'noreply', State#state{proxy=Args}};
handle_other(Verb, Args, State) ->
    %% You can implement other SMTP verbs here, if you need to
    lager:debug("500 Error: command not recognized : '~s ~s'",[Verb,Args]),
    {["500 Error: command not recognized : '", Verb, "'"], State}.

-spec handle_AUTH('login' | 'plain' | 'cram-md5', binary(), binary() | {binary(), binary()}, state()) ->
                         'error'.
handle_AUTH(_Type, _Username, _Password, _State) ->
    'error'.

-spec handle_STARTTLS(state()) -> state().
handle_STARTTLS(State) ->
    lager:debug("SMTP TLS Started"),
    State.

-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

-spec terminate(any(), state()) ->  {'ok', any(), state()}.
terminate('normal', State) ->
    _ = kz_util:spawn(fun handle_message/1, [State]),
    {'ok', 'normal', State};
terminate(Reason, State) ->
    lager:debug("terminate ~p", [Reason]),
    {'ok', Reason, State}.

%%% Internal Functions %%%

-spec handle_message(state()) -> 'ok'.
handle_message(#state{errors=[_Error | _Errors]}=State) ->
    maybe_faxbox_log(State);
handle_message(#state{doc='undefined'}=State) ->
    maybe_faxbox_log(State#state{errors=[<<"no fax documents to save">>]});
handle_message(#state{filename='undefined'}=State) ->
    maybe_faxbox_log(State#state{errors=[<<"no fax attachment to save">>]});
handle_message(#state{errors=[], faxbox='undefined'}=State) ->
    maybe_faxbox_log(State#state{errors=[<<"no previous errors but no faxbox doc">>]});
handle_message(#state{filename=Filename
                         ,content_type=_CT
                         ,doc=Doc
                         ,errors=[]
                        }=State) ->
    lager:debug("checking file ~s", [Filename]),
    case file:read_file(Filename) of
        {'ok', FileContents} ->
            CT = kz_mime:from_filename(Filename),
            case fax_util:save_fax_docs([Doc], FileContents, CT) of
                'ok' ->
                    lager:debug("smtp fax document saved"),
                    kz_util:delete_file(Filename);
                {'error', Error} -> maybe_faxbox_log(State#state{errors=[Error]})
            end;
        _Else ->
            Error = kz_util:to_binary(io_lib:format("error reading attachment ~s", [Filename])),
            maybe_faxbox_log(State#state{errors=[Error]})
    end.

-spec maybe_system_report(state()) -> 'ok'.
maybe_system_report(#state{faxbox='undefined', account_id='undefined'}=State) ->
    case kapps_config:get(?CONFIG_CAT, <<"report_anonymous_system_errors">>, 'false') of
        'true' -> system_report(State);
        'false' -> 'ok'
    end;
maybe_system_report(State) ->
    case kapps_config:get(?CONFIG_CAT, <<"report_faxbox_system_errors">>, 'true') of
        'true' -> system_report(State);
        'false' -> 'ok'
    end.

-spec maybe_faxbox_log(state()) -> 'ok'.
maybe_faxbox_log(#state{account_id='undefined'}=State) ->
    maybe_system_report(State);
maybe_faxbox_log(#state{faxbox='undefined', account_id=AccountId}=State) ->
    maybe_faxbox_log(AccountId, kz_json:new(), State);
maybe_faxbox_log(#state{faxbox=JObj, account_id=AccountId}=State) ->
    maybe_faxbox_log(AccountId, JObj, State).

-spec maybe_faxbox_log(ne_binary(), kz_json:object(), state()) -> 'ok'.
maybe_faxbox_log(AccountId, JObj, State) ->
    case kz_json:is_true(<<"log_errors">>, JObj, 'false')
        orelse ( kapps_account_config:get_global(AccountId, ?CONFIG_CAT, <<"log_faxbox_errors">>, 'true')
                 andalso kz_json:is_true(<<"log_errors">>, JObj, 'true')
               )
    of
        'true' -> faxbox_log(State);
        'false' -> maybe_system_report(State)
    end.

-spec system_report(state()) -> 'ok'.
system_report(#state{errors=[Error | _]}=State) ->
    Props = to_proplist(State),
    Notify = props:filter_undefined(
               [{<<"Subject">>, <<"fax smtp error">>}
                ,{<<"Message">>, Error}
                ,{<<"Details">>, kz_json:from_list(Props)}
                ,{<<"Account-ID">>, props:get_value(<<"Account-ID">>, Props)}
                | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
               ]),
    kz_amqp_worker:cast(Notify, fun kapi_notifications:publish_system_alert/1).

-spec faxbox_log(state()) -> 'ok'.
faxbox_log(#state{account_id=AccountId}=State) ->
    AccountDb = kazoo_modb:get_modb(AccountId),
    Doc = kz_json:normalize(
            kz_json:from_list(
              [{<<"pvt_account_id">>, AccountId}
               ,{<<"pvt_account_db">>, AccountDb}
               ,{<<"pvt_type">>, <<"fax_smtp_log">>}
               ,{<<"pvt_created">>, kz_util:current_tstamp()}
               ,{<<"_id">>, error_doc()}
               | to_proplist(State)
              ]
             )
           ),
    kazoo_modb:save_doc(AccountId, Doc),
    maybe_system_report(State).

-spec error_doc() -> ne_binary().
error_doc() ->
    {Year, Month, _} = erlang:date(),
    <<(kz_util:to_binary(Year))/binary,(kz_util:pad_month(Month))/binary
      ,"-",(kz_util:rand_hex_binary(16))/binary
    >>.

-spec to_proplist(state()) -> kz_proplist().
to_proplist(#state{}=State) ->
    props:filter_undefined(
      [{<<"To">>, State#state.to}
       ,{<<"From">>, State#state.from}
       ,{<<"Original-Number">>, State#state.original_number}
       ,{<<"Translated-Number">>, State#state.number}
       ,{<<"FaxBox-Domain">>, State#state.faxbox_email}
       ,{<<"FaxBox-Owner-ID">>, State#state.owner_id}
       ,{<<"FaxBox-Owner-Email">>, State#state.owner_email}
       ,{<<"Content-Type">>, State#state.content_type}
       ,{<<"Filename">>, State#state.filename}
       ,{<<"Errors">>, lists:reverse(State#state.errors)}
       ,{<<"Account-ID">>, State#state.account_id}
       | faxbox_to_proplist(State#state.faxbox)
         ++ faxdoc_to_proplist(State#state.doc)
      ]).


-spec faxbox_to_proplist(api_object()) -> kz_proplist().
faxbox_to_proplist('undefined') -> [];
faxbox_to_proplist(JObj) ->
    props:filter_undefined(
      [{<<"FaxBox-ID">>, kz_doc:id(JObj)}
      ]
     ).

-spec faxdoc_to_proplist(api_object()) -> kz_proplist().
faxdoc_to_proplist('undefined') -> [];
faxdoc_to_proplist(JObj) ->
    props:filter_undefined(
      [{<<"FaxDoc-ID">>, kz_doc:id(JObj)}
       ,{<<"FaxDoc-DB">>, kz_doc:account_db(JObj)}
      ]
     ).

-spec reset(state()) -> state().
reset(State) ->
    State#state{owner_id = 'undefined'
                ,owner_email = 'undefined'
                ,faxbox_email = 'undefined'
                ,faxbox = 'undefined'
                ,original_number = 'undefined'
                ,number = 'undefined'
                ,account_id = 'undefined'
               }.

-spec check_faxbox(state()) ->
                          {'ok', state()} |
                          {'error', string(), state()}.
check_faxbox(#state{to=To}= State) ->
    case binary:split(kz_util:to_lower_binary(To), <<"@">>) of
        [FaxNumber, Domain] ->
            Number = fax_util:filter_numbers(FaxNumber),
            check_number(
              maybe_faxbox(State#state{faxbox_email=Domain
                                       ,original_number=FaxNumber
                                       ,number=Number
                                      }
                          )
             );
        _ ->
            lager:debug("invalid address"),
            {'error', "554 Not Found", State#state{errors=[<<"invalid address">>]}}
    end.

-spec check_number(state()) ->
                          {'ok', state()} |
                          {'error', string(), state()}.
check_number(#state{number= <<>>
                    ,original_number=Number
                    ,faxbox='undefined'
                   }=State) ->
    Error = kz_util:to_binary(
              io_lib:format("fax number ~s is empty, no faxbox to report to", [Number])
             ),
    lager:debug(Error),
    {'error', "554 Not Found", State#state{errors=[Error]}};
check_number(#state{number= <<>>
                    ,original_number=Number
                    ,errors=Errors
                   }=State) ->
    Error = kz_util:to_binary(io_lib:format("fax number ~s is empty", [Number])),
    lager:debug(Error),
    {'error', "554 Not Found", State#state{errors=[Error | Errors]}};
check_number(#state{faxbox='undefined'}=State) ->
    {'error', "554 Not Found", State};
check_number(#state{}=State) ->
    check_permissions(State).

-spec check_permissions(state()) ->
                               {'ok', state()} |
                               {'error', string(), state()}.
-spec check_permissions(state(), ne_binaries()) ->
                               {'ok', state()} |
                               {'error', string(), state()}.
check_permissions(#state{from=_From
                         ,owner_email=OwnerEmail
                         ,faxbox=FaxBoxDoc
                        }=State) ->
    lager:debug("checking if ~s can send to ~p."
                ,[_From, kz_json:get_value(<<"name">>, FaxBoxDoc)]
               ),
    case kz_json:get_value(<<"smtp_permission_list">>, FaxBoxDoc, []) of
        [] when OwnerEmail =:= 'undefined' ->
            check_empty_permissions(State);
        Permissions ->
            check_permissions(State, Permissions)
    end.

check_permissions(#state{from=From
                         ,owner_email=OwnerEmail
                         ,faxbox=FaxBoxDoc
                         ,errors=Errors
                        }=State, Permissions) ->
    case lists:any(fun(A) -> match(From, A) end, Permissions)
        orelse From =:= OwnerEmail
    of
        'true' -> add_fax_document(State);
        'false' ->
            Error = kz_util:to_binary(
                      io_lib:format("address ~s is not allowed on faxbox ~s"
                                   ,[From, kz_doc:id(FaxBoxDoc)]
                                   )
                     ),
            lager:debug(Error),
            {'error', "554 not allowed", State#state{errors=[Error | Errors]}}
    end.

-spec check_empty_permissions(state()) ->
                                     {'ok', state()} |
                                     {'error', string(), state()}.
check_empty_permissions(#state{errors=Errors}=State) ->
    case kapps_config:get_is_true(?CONFIG_CAT, <<"allow_all_addresses_when_empty">>, 'false') of
        'true' -> add_fax_document(State);
        'false' ->
            Error = <<"faxbox permissions is empty and policy doesn't allow it">>,
            lager:debug(Error),
            {'error', "554 not allowed", State#state{errors=[Error | Errors]}}
    end.

-spec match(binary(), binary()) -> boolean().
match(Address, Element) ->
    re:run(Address, Element) =/= 'nomatch'.

-spec maybe_faxbox(state()) -> state().
maybe_faxbox(#state{faxbox_email=Domain}=State) ->
    ViewOptions = [{'key', Domain}, 'include_docs'],
    case kz_datamgr:get_results(?KZ_FAXES_DB, <<"faxbox/email_address">>, ViewOptions) of
        {'ok', [JObj]} ->
            FaxBoxDoc= kz_json:get_value(<<"doc">>,JObj),
            AccountId = kz_doc:account_id(FaxBoxDoc),
            maybe_faxbox_owner(State#state{faxbox=FaxBoxDoc, account_id=AccountId});
        _ -> maybe_faxbox_domain(State)
    end.

-spec maybe_faxbox_owner(state()) -> state().
maybe_faxbox_owner(#state{faxbox=FaxBoxDoc}=State) ->
    case kz_json:get_value(<<"owner_id">>, FaxBoxDoc) of
        'undefined' -> State;
        OwnerId ->
            AccountId = kz_doc:account_id(FaxBoxDoc),
            AccountDb = kz_util:format_account_id(AccountId, 'encoded'),
            case kz_datamgr:open_cache_doc(AccountDb, OwnerId) of
                {'ok', OwnerDoc} ->
                    OwnerEmail = kz_json:get_value(<<"email">>, OwnerDoc),
                    State#state{owner_id=OwnerId, owner_email=OwnerEmail};
                _ -> State
            end
    end.

-spec maybe_faxbox_domain(state()) -> state().
maybe_faxbox_domain(#state{faxbox_email=Domain}=State) ->
    ViewOptions = [{'key', Domain}],
    case kz_datamgr:get_results(?KZ_ACCOUNTS_DB, <<"accounts/listing_by_realm">>, ViewOptions) of
        {'ok', []} ->
            Error = <<"realm ", Domain/binary, " not found in accounts db">>,
            lager:debug(Error),
            State#state{errors=[Error]};
        {'ok', [JObj]} ->
            AccountId = kz_doc:id(JObj),
            maybe_faxbox_by_owner_email(AccountId, State#state{account_id=AccountId});
        {'ok', [_JObj | _JObjs]} ->
            Error = <<"accounts query by realm ", Domain/binary, " return more than one document">>,
            lager:debug(Error),
            State#state{errors=[Error]};
        {'error', _E} ->
            Error = <<"error searching realm ", Domain/binary>>,
            lager:debug("error ~p querying realm in accounts database",[_E]),
            State#state{errors=[Error]}
    end.

-spec maybe_faxbox_by_owner_email(ne_binary(), state()) -> state().
maybe_faxbox_by_owner_email(AccountId, #state{errors=Errors
                                              ,from=From
                                             }=State) ->
    ViewOptions = [{'key', From}],
    AccountDb = kz_util:format_account_db(AccountId),
    case kz_datamgr:get_results(AccountDb, <<"users/list_by_email">>, ViewOptions) of
        {'ok', []} ->
            Error = kz_util:to_binary(io_lib:format("user ~s does not exist in account ~s, trying by rules",[From, AccountId])),
            lager:debug(Error),
            maybe_faxbox_by_rules(AccountId, State#state{errors=[Error | Errors]});
        {'ok', [JObj]} ->
            OwnerId = kz_doc:id(JObj),
            maybe_faxbox_by_owner_id(AccountId, OwnerId, State);
        {'ok', [_JObj | _JObjs]} ->
            Error = kz_util:to_binary(io_lib:format("more then one user with email ~s in account ~s, trying by rules", [From, AccountId])),
            lager:debug(Error),
            maybe_faxbox_by_rules(AccountId, State#state{errors=[Error | Errors]});
        {'error', _E} ->
            Error = kz_util:to_binary(io_lib:format("error ~p getting user by email ~s  in account ~s, trying by rules",[_E, From, AccountId])),
            lager:debug(Error),
            maybe_faxbox_by_rules(AccountId, State#state{errors=[Error | Errors]})
    end.

-spec maybe_faxbox_by_owner_id(ne_binary(), ne_binary(),state()) -> state().
maybe_faxbox_by_owner_id(AccountId, OwnerId, #state{errors=Errors, from=From}=State) ->
    ViewOptions = [{'key', OwnerId}, 'include_docs'],
    AccountDb = kz_util:format_account_db(AccountId),
    case kz_datamgr:get_results(AccountDb, <<"faxbox/list_by_ownerid">>, ViewOptions) of
        {'ok', [JObj]} ->
            State#state{faxbox=kz_json:get_value(<<"doc">>,JObj)
                        ,owner_id=OwnerId
                        ,owner_email=From
                        ,errors=[]
                       };
        {'ok', [_JObj | _JObjs]} ->
            Error = kz_util:to_binary(io_lib:format("user ~s : ~s has multiples faxboxes", [OwnerId, From])),
            maybe_faxbox_by_rules(AccountId
                                  ,State#state{owner_id=OwnerId
                                               ,owner_email=From
                                               ,errors=[Error | Errors]
                                              }
                                 );
        _ ->
            Error = kz_util:to_binary(io_lib:format("user ~s : ~s does not have a faxbox", [OwnerId, From])),
            lager:debug("user ~s : ~s from account ~s does not have a faxbox, trying by rules"
                        ,[OwnerId, From, AccountId]
                       ),
            maybe_faxbox_by_rules(AccountId
                                  ,State#state{owner_id=OwnerId
                                               ,owner_email=From
                                               ,errors=[Error | Errors]
                                              }
                                 )
    end.

-spec maybe_faxbox_by_rules(ne_binary() | kz_json:objects(), state()) -> state().
maybe_faxbox_by_rules(AccountId, #state{errors=Errors}=State)
  when is_binary(AccountId) ->
    ViewOptions = ['include_docs'],
    AccountDb = kz_util:format_account_db(AccountId),
    case kz_datamgr:get_results(AccountDb, <<"faxbox/email_permissions">>, ViewOptions) of
        {'ok', []} ->
            Error = <<"no faxboxes for account ", AccountId/binary>>,
            lager:debug(Error),
            State#state{errors=[Error | Errors]};
        {'ok', JObjs} -> maybe_faxbox_by_rules(JObjs, State#state{account_id=AccountId});
        {'error', _E} ->
            Error = <<"error getting faxbox email permissions for account ", AccountId/binary>>,
            lager:debug("error getting faxbox email permissions for account ~s : ~p", [AccountId, _E]),
            State#state{errors=[Error | Errors]}
    end;
maybe_faxbox_by_rules([], #state{account_id=AccountId
                                 ,from=From
                                 ,errors=Errors
                                }=State) ->
    Error = <<"no mathing rules in account ", AccountId/binary, " for ", From/binary >>,
    lager:debug(Error),
    State#state{errors=[Error | Errors]};
maybe_faxbox_by_rules([JObj | JObjs], #state{from=From}=State) ->
    Key = kz_json:get_value(<<"key">>, JObj),
    case match(From, Key) of
        'true' -> State#state{errors=[], faxbox=kz_json:get_value(<<"doc">>, JObj)};
        'false' -> maybe_faxbox_by_rules(JObjs, State)
    end.

-spec add_fax_document(state()) ->
                              {'ok', state()} |
                              {'error', string(), state()}.
add_fax_document(#state{doc='undefined'
                        ,from=From
                        ,owner_email=OwnerEmail
                        ,number=FaxNumber
                        ,faxbox=FaxBoxDoc
                        ,session_id=Id
                       }=State) ->
    FaxBoxId = kz_doc:id(FaxBoxDoc),
    AccountId = kz_doc:account_id(FaxBoxDoc),
    AccountDb = ?KZ_FAXES_DB,
    ResellerId = case kzd_services:reseller_id(FaxBoxDoc) of
                     'undefined' -> kz_services:find_reseller_id(AccountId);
                     TheResellerId -> TheResellerId
                 end,

    SendToKey = [<<"notifications">>
                 ,<<"outbound">>
                 ,<<"email">>
                 ,<<"send_to">>
                ],

    FaxBoxEmailNotify = kz_json:get_value(SendToKey, FaxBoxDoc, []),
    FaxBoxNotify = kz_json:set_value(SendToKey
                                     ,fax_util:notify_email_list(From, OwnerEmail , FaxBoxEmailNotify)
                                     ,FaxBoxDoc
                                    ),
    Notify = kz_json:get_value([<<"notifications">>, <<"outbound">>], FaxBoxNotify),

    Props = props:filter_undefined(
              [{<<"from_name">>, kz_json:get_value(<<"caller_name">>, FaxBoxDoc)}
               ,{<<"fax_identity_name">>, kz_json:get_value(<<"fax_header">>, FaxBoxDoc)}
               ,{<<"from_number">>, kz_json:get_value(<<"caller_id">>, FaxBoxDoc)}
               ,{<<"fax_identity_number">>, kz_json:get_value(<<"fax_identity">>, FaxBoxDoc)}
               ,{<<"fax_timezone">>, kzd_fax_box:timezone(FaxBoxDoc)}
               ,{<<"to_name">>, FaxNumber}
               ,{<<"to_number">>, FaxNumber}
               ,{<<"retries">>, kzd_fax_box:retries(FaxBoxDoc, 3)}
               ,{<<"notifications">>, Notify}
               ,{<<"faxbox_id">>, FaxBoxId}
               ,{<<"folder">>, <<"outbox">>}
               ,{<<"_id">>, Id}
              ]),

    Doc = kz_json:set_values([{<<"pvt_type">>, <<"fax">>}
                              ,{<<"pvt_job_status">>, <<"attaching files">>}
                              ,{<<"pvt_created">>, kz_util:current_tstamp()}
                              ,{<<"attempts">>, 0}
                              ,{<<"pvt_account_id">>, AccountId}
                              ,{<<"pvt_account_db">>, AccountDb}
                              ,{<<"pvt_reseller_id">>, ResellerId}
                             ]
                             ,kz_json_schema:add_defaults(kz_json:from_list(Props), <<"faxes">>)
                            ),
    lager:debug("added fax document from smtp : ~p", [Doc]),
    {'ok', State#state{doc=Doc}};
add_fax_document(#state{doc=Doc}=State) ->
    lager:debug("add fax document called but already has a doc : ~p", [Doc]),
    {'ok', State}.


%% ====================================================================
%% Internal functions
%% ====================================================================
-spec process_message(ne_binary(), ne_binary(), kz_proplist(), kz_proplist(), binary() | mimemail:mimetuple(), state()) ->
                             {'ok', state()}.
process_message(<<"multipart">>, <<"mixed">>, _Headers, _Parameters, Body, #state{errors=Errors}=State) ->
    lager:debug("processing multipart/mixed"),
    case Body of
        {Type, SubType, _HeadersPart, ParametersPart, BodyPart} ->
            lager:debug("processing ~s/~s", [Type, SubType]),
            maybe_process_part(<<Type/binary, "/", SubType/binary>>
                         ,ParametersPart
                         ,BodyPart
                         ,State
                        );
        [{Type, SubType, _HeadersPart, _ParametersPart, _BodyParts}|_OtherParts]=Parts ->
            lager:debug("processing multiple parts, first is ~s/~s", [Type, SubType]),
            process_parts(Parts, State);
        A ->
            lager:debug("missed processing ~p", [A]),
            {'ok', State#state{errors=[<<"invalid body">> | Errors]}}
    end;
process_message(_Type, _SubType, _Headers, _Parameters, _Body, State) ->
    lager:debug("skipping ~s/~s",[_Type, _SubType]),
    {'ok', State}.

-spec process_parts([mimemail:mimetuple()], state()) -> {'ok', state()}.
process_parts([], #state{filename='undefined'
                         ,errors=Errors
                        }=State) ->
    {'ok', State#state{errors=[<<"no valid attachment">> | Errors]}};
process_parts([], State) ->
    {'ok', State};
process_parts([{Type, SubType, _Headers, Parameters, BodyPart}
               |Parts
              ], State) ->
    {_ , NewState}
        = maybe_process_part(fax_util:normalize_content_type(<<Type/binary, "/", SubType/binary>>)
                       ,Parameters
                       ,BodyPart
                       ,State
                      ),
    process_parts(Parts, NewState).

-spec maybe_process_part(ne_binary(), kz_proplist(), binary() | mimemail:mimetuple(), state()) ->
                          {'ok', state()}.
maybe_process_part(<<"application/octet-stream">>, Parameters, Body, State) ->
    lager:debug("part is application/octet-stream, try check attachment filename extension"),
    case props:get_value(<<"disposition">>, Parameters) of
        <<"attachment">> ->
            Props = props:get_value(<<"disposition-params">>, Parameters, []),
            Filename = kz_util:to_lower_binary(props:get_value(<<"filename">>, Props, <<>>)),
            case kz_mime:from_filename(Filename) of
                <<"application/octet-stream">> ->
                    lager:debug("unable to determine content-type for extension : ~s", [Filename]),
                    {'ok', State};
                CT ->
                    maybe_process_part(CT, Parameters, Body, State)
            end;
         _Else ->
            lager:debug("part is not attachment"),
            {'ok', State}
    end;
maybe_process_part(CT, _Parameters, Body, State) ->
    case {is_allowed_content_type(CT), CT} of
        {true, <<"image/tiff">>} ->
            process_part(CT, Body, State);
        {true, <<"image/", _/binary>>} ->
            maybe_process_image(CT, Body, State);
        {true, _} ->
            process_part(CT, Body, State);
        _ ->
            lager:debug("ignoring part ~s", [CT]),
            {'ok', State}
    end.

-spec process_part(ne_binary(), binary() | mimemail:mimetuple(), state()) -> {'ok', state()}.
process_part(CT, Body, State) ->
    lager:debug("part is ~s", [CT]),
    Extension = kz_mime:to_extension(CT),
    {'ok', Filename} = write_tmp_file(Extension, Body),
    {'ok', State#state{filename=Filename
                       ,content_type=CT
                      }}.

-spec is_allowed_content_type(ne_binary()) -> boolean().
is_allowed_content_type(CT) ->
    AllowedCT = kapps_config:get(?CONFIG_CAT, <<"allowed_content_types">>, ?DEFAULT_ALLOWED_CONTENT_TYPES),
    DeniedCT = kapps_config:get(?CONFIG_CAT, <<"denied_content_types">>, [{[{<<"prefix">>, <<"image/">>}]}]),
    AllowedBy = content_type_matched_by(CT, AllowedCT, <<>>),
    DeniedBy = content_type_matched_by(CT, DeniedCT, <<>>),
    byte_size(AllowedBy) > byte_size(DeniedBy).

-spec content_type_matched_by(ne_binary(), [ne_binary() | kz_json:object()], binary()) -> binary().
content_type_matched_by(CT, [CT | _T], _) ->
    CT;
content_type_matched_by(CT, [Type | T], GreaterMatch) when is_binary(Type) ->
    content_type_matched_by(CT, T, GreaterMatch);
content_type_matched_by(CT, [Type | T], GreaterMatch) ->
    Matched = content_type_matched_json(CT, Type),
    case byte_size(Matched) > byte_size(GreaterMatch) of
        'true' -> content_type_matched_by(CT, T, Matched);
        'false' -> content_type_matched_by(CT, T, GreaterMatch)
    end;
content_type_matched_by(_CT, [], GreaterMatch) ->
    GreaterMatch.

-spec content_type_matched_json(ne_binary(), kz_json:object()) -> binary().
content_type_matched_json(CT, Type) ->
    case kz_json:is_json_object(Type) of
        'false' -> <<>>;
        'true' ->
            content_type_matched_json(CT, Type, <<"type">>)
    end.

-spec content_type_matched_json(ne_binary(), kz_json:object(), ne_binary()) -> binary().
content_type_matched_json(CT, Type, <<"type">> = Field) ->
    case kz_json:get_binary_value(Field, Type) of
        CT -> CT;
        _ -> content_type_matched_json(CT, Type, <<"prefix">>)
    end;
content_type_matched_json(CT, Type, <<"prefix">> = Field) ->
    Prefix = kz_json:get_binary_value(Field, Type, <<>>),
    L = byte_size(Prefix),
    case {L, CT} of
        {0, CT} -> <<>>;
        {_, <<Prefix:L/binary, _/binary>>} -> Prefix;
        {_, _} -> <<>>
    end.

-spec maybe_process_image(ne_binary(), binary() | mimemail:mimetyple(), state()) -> {'ok', state()}.
maybe_process_image(CT, Body, State) ->
    case kapps_config:get_binary(?CONFIG_CAT, <<"image_min_size">>, <<"700x10">>) of
        'undefined' ->
            lager:debug("ignoring part ~s", [CT]),
            {'ok', State};
        Size ->
            maybe_process_image(CT, Body, Size, State)
    end.

-spec maybe_process_image(ne_binary(), binary() | mimemail:mimetuple(), ne_binary(), state()) -> {'ok', state()}.
maybe_process_image(CT, Body, Size, State) ->
    {MinX, MinY} = case re:split(Size, "x") of
                       [P] -> {kz_util:to_integer(P), kz_util:to_integer(P)};
                       [X, Y] -> {kz_util:to_integer(X), kz_util:to_integer(Y)}
                   end,
    {'ok', NewState = #state{filename = Filename}} = process_part(CT, Body, State),
    Cmd = io_lib:format(?IMAGE_SIZE_CMD_FMT, [Filename]),
    [W, H] = re:split(os:cmd(Cmd), "x"),
    Width = kz_util:to_integer(W),
    Height = kz_util:to_integer(H),
    case MinX =< Width
        andalso MinY =< Height
    of
        'true' ->
            {'ok', NewState};
        'false' ->
            lager:debug("ignoring part ~s", [CT]),
            kz_util:delete_file(Filename),
            {'ok', State}
    end.

-spec write_tmp_file(ne_binary(), binary() | mimemail:mimetuple()) ->
                            {'ok', api_binary()} |
                            {'error', any()}.
-spec write_tmp_file(api_binary() , ne_binary(), binary() | mimemail:mimetuple()) ->
                            {'ok', api_binary()} |
                            {'error', any()}.
write_tmp_file(Extension, Body) ->
    write_tmp_file('undefined', Extension, Body).

write_tmp_file('undefined', Extension, Body) ->
    Filename = <<"/tmp/email_attachment_", (kz_util:to_binary(kz_util:current_tstamp()))/binary>>,
    write_tmp_file(Filename, Extension, Body);
write_tmp_file(Filename, Extension, Body) ->
    File = <<Filename/binary, ".", Extension/binary>>,
    case file:write_file(File, Body, []) of
        'ok' -> {'ok', File};
        {'error', _}=Error ->
            lager:debug("error writing file ~s : ~p", [Filename, Error]),
            Error
    end.
