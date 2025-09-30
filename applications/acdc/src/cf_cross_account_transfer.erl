%%%-------------------------------------------------------------------
%%% @copyright (C) 2024, 2600Hz
%%% @doc
%%% Cross-account call transfer module for Kazoo
%%% Allows transferring calls between different accounts with proper
%%% permission validation and account hierarchy checks
%%% @end
%%%-------------------------------------------------------------------
-module(cf_cross_account_transfer).

-behaviour(gen_cf_action).

-export([handle/2]).

-include_lib("callflow/src/callflow.hrl").

-define(DEFAULT_TIMEOUT, 20).
-define(MOD_CONFIG_CAT, <<"callflow.cross_account_transfer">>).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Entry point for this module, attempts to transfer call to
%% destination in a different account
%% @end
%%--------------------------------------------------------------------
-spec handle(kz_json:object(), kapps_call:call()) -> 'ok'.
handle(Data, Call) ->
    Destination = kapps_call:kvs_fetch('cf_capture_group', Call),
    lager:info("attempting cross-account transfer"),
    
    case get_transfer_data(Data, Destination) of
        {'error', Reason} ->
            lager:warning("invalid transfer data: ~p", [Reason]),
            cf_exe:continue(Call);
        {'ok', TransferData} ->
            attempt_transfer(TransferData, Call)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Extract and validate transfer data from callflow configuration
%% @end
%%--------------------------------------------------------------------
-spec get_transfer_data(kz_json:object(), binary()) -> 
    {'ok', map()} | {'error', term()}.
get_transfer_data(Data, Destination) ->
    TargetAccount = kz_json:get_ne_binary_value(<<"target_account">>, Data),
    TransferType = kz_json:get_ne_binary_value(<<"transfer_type">>, Data, <<"blind">>),
    
    case {TargetAccount, Destination} of
        {'undefined', _} ->
            {'error', 'missing_target_account'};
        {_, 'undefined'} ->
            {'error', 'missing_destination'};
        {Account, Dest} ->
            {'ok', #{
                'target_account' => Account,
                'destination' => Dest,
                'transfer_type' => TransferType,
                'timeout' => kz_json:get_integer_value(<<"timeout">>, Data, ?DEFAULT_TIMEOUT),
                'ringback' => kz_json:get_ne_binary_value(<<"ringback">>, Data),
                'require_auth' => kz_json:is_true(<<"require_auth">>, Data, 'true')
            }}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt the cross-account transfer with permission validation
%% @end
%%--------------------------------------------------------------------
-spec attempt_transfer(map(), kapps_call:call()) -> 'ok'.
attempt_transfer(#{
    'target_account' := TargetAccount,
    'destination' := _Destination,
    'transfer_type' := _TransferType,
    'require_auth' := RequireAuth
} = TransferData, Call) ->
    
    SourceAccount = kapps_call:account_id(Call),
    
    case validate_cross_account_permission(SourceAccount, TargetAccount, RequireAuth) of
        'false' ->
            lager:warning("cross-account transfer denied: ~s -> ~s", [SourceAccount, TargetAccount]),
            play_error_tone(Call),
            cf_exe:continue(Call);
        'true' ->
            execute_transfer(TransferData, Call),
            cf_exe:control_usurped(Call)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Validate if cross-account transfer is permitted
%% @end
%%--------------------------------------------------------------------
validate_cross_account_permission(SourceAccount, TargetAccount, RequireAuth) ->
    lager:info("validating cross-account transfer permission: ~s -> ~s", [SourceAccount, TargetAccount]),
    case SourceAccount =:= TargetAccount of
        'true' -> 'true';  % Same account, always allowed
        'false' when not RequireAuth -> 'true';  % Auth disabled
        'false' ->
            % Check if accounts are in same account tree
            case {get_account_realm(SourceAccount), get_account_realm(TargetAccount)} of
                {'undefined', _} -> 'false';
                {_, 'undefined'} -> 'false';
                {SourceRealm, TargetRealm} ->
                    check_account_hierarchy(SourceAccount, TargetAccount) orelse
                    check_cross_account_permission(SourceRealm, TargetRealm)
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check if accounts are in the same hierarchy tree
%% @end
%%--------------------------------------------------------------------
check_account_hierarchy(SourceAccount, TargetAccount) ->
    case kzd_accounts:fetch(SourceAccount) of
        {'error', _} -> 'false';
        {'ok', SourceDoc} ->
            case kzd_accounts:fetch(TargetAccount) of
                {'error', _} -> 'false';
                {'ok', TargetDoc} ->
                    SourceTree = kzd_accounts:tree(SourceDoc, []),
                    TargetTree = kzd_accounts:tree(TargetDoc, []),
                    has_common_ancestor(SourceTree, TargetTree)
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check if account trees have a common ancestor
%% @end
%%--------------------------------------------------------------------
has_common_ancestor(SourceTree, TargetTree) ->
    sets:size(
        sets:intersection(
            sets:from_list(SourceTree),
            sets:from_list(TargetTree)
        )
    ) > 0.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check cross-account permission via system configuration
%% @end
%%--------------------------------------------------------------------
check_cross_account_permission(SourceRealm, TargetRealm) ->
    case kapps_config:get_is_true(?MOD_CONFIG_CAT, <<"allow_cross_realm">>, 'false') of
        'true' -> 'true';
        'false' -> SourceRealm =:= TargetRealm
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Execute the actual transfer
%% @end
%%--------------------------------------------------------------------
-spec execute_transfer(map(), kapps_call:call()) -> 'ok'.
execute_transfer(#{
    'target_account' := TargetAccount,
    'destination' := Destination,
    'transfer_type' := <<"attended">>,
    'timeout' := _Timeout
}, Call) ->
    
    lager:info("executing attended cross-account transfer to ~s@~s", [Destination, TargetAccount]),

     % Update the call account and realm for the transfer
    kapps_call_command:set('undefined',
    kz_json:from_list([
        {<<"Account-ID">>, TargetAccount}
        ,{<<"Account-Realm">>, get_account_realm(TargetAccount)}
    ]),
    Call),

    %% Execute transfer command directly
    kapps_call_command:transfer(<<"blind">>, Destination, Call);

execute_transfer(#{
    'target_account' := TargetAccount,
    'destination' := Destination,
    'transfer_type' := <<"blind">>
}, Call) ->
    
    lager:info("executing blind cross-account transfer to ~s@~s", [Destination, TargetAccount]),
    
    % For blind transfer, redirect the call to target account
    TargetURI = build_target_uri(Destination, TargetAccount),
    
    case kapps_call_command:redirect(TargetURI, Call) of
        'ok' ->
            lager:info("blind transfer initiated successfully"),
            cf_exe:stop(Call);
        {'error', Reason} ->
            lager:warning("blind transfer failed: ~p", [Reason]),
            play_error_tone(Call),
            cf_exe:continue(Call)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Originate call to target destination
%% @end
%%--------------------------------------------------------------------
% originate_target_call(TargetAccount, Call, Destination) ->
%     case get_endpoint(Destination, TargetAccount) of
%         [] ->
%             lager:info("no endpoints found"),
%             {'error', 'no_endpoints'};
%         EPL ->
%             lager:info("found endpoints ~p for destination ~s", [EPL, Destination]),

%             % Update the A-Leg with the target account details
%             kapps_call_command:set('undefined',
%             kz_json:from_list([
%                 {<<"Account-ID">>, TargetAccount}
%                 ,{<<"Account-Realm">>, TargetRealm = get_account_realm(TargetAccount)}
%             ]),
%             Call),

%             TargetCall = updated_call(TargetAccount, Call),
%             lager:info("set call account to ~s with realm ~s", [TargetAccount, TargetRealm]),

%             %% Wait a moment for the set to take effect
%             timer:sleep(100),

%             lager:debug("Account Old ID: ~s, Old DB: ~s", [kapps_call:account_id(Call), kapps_call:account_db(Call)]),
%             lager:debug("Account New ID: ~s, New DB: ~s", [kapps_call:account_id(TargetCall), kapps_call:account_db(TargetCall)]),

%             %% Get the first endpoint's contact
%             [FirstEndpoint|_] = build_endpoints(EPL, TargetCall),

%             lager:info("using endpoint ~p for origination", [FirstEndpoint]),
            
%              %% Extract To-User and To-Realm from endpoint
%             ToUser = kz_json:get_value(<<"To-User">>, FirstEndpoint),
%             ToRealm = kz_json:get_value(<<"To-Realm">>, FirstEndpoint),
%             TransferDest = <<ToUser/binary ," XML context_2">>,

%             lager:info("originating call to ~s@~s, Destination: ~s", [ToUser, ToRealm, TransferDest]),
            
%             %% Execute transfer command directly
%             kapps_call_command:transfer(<<"blind">>, Destination, Call),
            
%             {'ok', <<"transferred">>}
%     end.

% get_endpoint(Number, AccountId)->
%     %% We need to get the user mapped to this number in the target account
%     Db = kz_util:format_account_db(AccountId),

%     case get_user(Db, Number) of
%         undefined -> [];
%         UserId -> 
%             lager:info("found user ~s for number ~s in account ~s", [UserId, Number, AccountId]),   
%             Endpoints = get_user_endpoints(Db, UserId),
%             lager:info("found endpoints ~p for user ~s", [Endpoints, UserId]),
%             Endpoints
%     end.    

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Build endpoint for origination
%% @end
%%--------------------------------------------------------------------
% build_endpoints(Ids, Call) ->
%     lists:foldl(fun(Id, Acc) ->
%         case kz_endpoint:build(Id, kz_json:new(), Call) of
%             {ok, Endpoints} -> Endpoints ++ Acc;
%             {error, _} -> Acc
%         end
%     end, [], Ids).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Build target URI for blind transfer
%% @end
%%--------------------------------------------------------------------
build_target_uri(Destination, TargetAccount) ->
    case kz_util:get_account_realm(TargetAccount) of
        'undefined' ->
            % Fallback to direct number
            <<"sip:", Destination/binary>>;
        Realm ->
            <<"sip:", Destination/binary, "@", Realm/binary>>
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Play error tone when transfer fails
%% @end
%%--------------------------------------------------------------------
-spec play_error_tone(kapps_call:call()) -> 'ok'.
play_error_tone(Call) ->
    Tone = kz_json:from_list([{<<"Frequencies">>, [<<"480">>, <<"620">>]}
                             ,{<<"Duration-ON">>, <<"250">>}
                             ,{<<"Duration-OFF">>, <<"250">>}
                             ,{<<"Repeat">>, 3}
                             ]),
    kapps_call_command:tones([Tone], Call).

-spec get_account_realm(kz_term:ne_binary()) -> kz_term:ne_binary().
get_account_realm(AccountId) ->
    Realm = kzd_accounts:fetch_realm(AccountId),
    lager:info("account realm: ~s", [Realm]),
    case Realm of
        'undefined' -> AccountId;
        Realm -> Realm
    end.

% get_user_endpoints(Db, UserId)->
%     Options = [{'key', UserId}],
%     case kz_datamgr:get_results(Db, <<"devices/listing_by_owner">>, Options) of
%             {'ok', Docs} ->
%                 lists:foldl(fun(Doc, Acc)->
%                     [kz_json:get_value(<<"id">>, Doc) | Acc]
%                 end, [], Docs);
%             {'error', Reason} ->
%                 lager:warning("error fetching endpoints for userId ~s, reason ~p", [UserId, Reason]),
%                 []
%         end.

% get_user(Db, Number)->
%     %% We need to get the user mapped to this number in the target account
%     Options = ['include_docs'],
%     case kz_datamgr:get_results(Db, <<"users/list_by_id">>, Options) of
%         {'ok', Docs} ->
%             case extract_user_id(Number, Docs) of
%                 [] ->
%                     lager:info("no user found for number ~s", [Number]),
%                     undefined;
%                 [UserId|_] ->
%                     UserId
%             end;
%         {'error', Reason} ->
%             lager:warning("error fetching users, reason: ~p", [Reason]),
%             undefined
%     end.

% extract_user_id(Number, Docs) ->
%     lists:foldl(fun(Doc, Acc)->
%         case kz_json:get_value([<<"doc">>, <<"caller_id">>, <<"internal">>, <<"number">>], Doc) of
%             Number -> [ kz_json:get_value(<<"id">>, Doc) | Acc ];
%             _ -> 
%                 Acc
%         end
%     end, [], Docs).

% updated_call(TargetAccount, Call)->
%      % Set necessary call parameters for the new call leg
%     Db = kz_util:format_account_db(TargetAccount),
%     Routines = [{F, V} || {F, V} <- [{fun kapps_call:set_account_db/2, Db}
%             ,{fun kapps_call:set_account_id/2, TargetAccount}
%             ,{fun kapps_call:set_resource_type/2, <<"audio">>}
%         ],
%         'undefined' =/= V
%     ],
%     kapps_call:exec(Routines, Call).
