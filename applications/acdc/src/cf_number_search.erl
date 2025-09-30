-module(cf_number_search).

-export([handle/2]).

-include_lib("callflow/src/callflow.hrl").

-spec handle(kz_json:object(), kapps_call:call()) -> 'ok'.
handle(_Data, Call) ->
    %%Number = kz_json:get_ne_binary_value(<<"queue_number">>, Data),
    %%CalledNumber = kapps_call:kvs_fetch('queue_number', Call),
    Number = kapps_call:kvs_fetch('cf_capture_group', Call),

    %%lager:info("Queue Number: ~s", [Number]),
    %%lager:info("Queue Number: ~s", [CalledNumber]),
    lager:info("Queue Number: ~s", [Number]),

    Accounts = kapps_util:get_all_accounts(),

    Results = lists:flatten([find_in_account(Account, Number) || Account <- Accounts]),
    lager:info("Following accounts can process call: ~p", [Results]),

    case length(Results) > 0 of
        true ->
            %% redirect the call to the first account found.
            [TargetAccount | _ ] = Results,

            lager:info("Sending call to the account ~s", [TargetAccount]),

             % For blind transfer, redirect the call to target account
            TargetURI = build_target_uri(Number, TargetAccount),
    
            case kapps_call_command:redirect(TargetURI, Call) of
                'ok' ->
                    lager:info("blind transfer initiated successfully"),
                    cf_exe:stop(Call);
                {'error', Reason} ->
                    lager:warning("blind transfer failed: ~p", [Reason]),
                    play_error_tone(Call),
                    cf_exe:continue(Call)
            end;
        false ->
            lager:info("no callflow found for number ~s", [Number]),
            cf_exe:continue(Call)
    end.

find_in_account(AccountId, Number) ->
    lager:info("Search for callflows number ~p in account ~p", [Number, AccountId]),
    Db = kz_util:format_account_db(AccountId),
    case kz_datamgr:get_results(Db, <<"callflows/listing_by_number">>,[{key, Number}]) of
        {ok, Callflows} ->
            lists:foldl(
              fun(_Doc, Acc) ->
                    [AccountId | Acc]
              end, [], Callflows);
        {error, _} ->
            []
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Play error tone when transfer fails
%% @end
%%--------------------------------------------------------------------
-spec play_error_tone(kapps_call:call()) -> 'ok'.
play_error_tone(Call) ->
    Tone = kz_json:from_list([{<<"Frequencies">>, [<<"480">>, <<"620">>]}, {<<"Duration-ON">>, <<"250">>}
                             , {<<"Duration-OFF">>, <<"250">>}, {<<"Repeat">>, 3}]),
    kapps_call_command:tones([Tone], Call).

build_target_uri(Destination, TargetAccount) ->
    case kzd_accounts:fetch_realm(TargetAccount) of
        'undefined' ->
            % Fallback to direct number
            <<"sip:", Destination/binary>>;
        Realm ->
            <<"sip:", Destination/binary, "@", Realm/binary>>
    end.