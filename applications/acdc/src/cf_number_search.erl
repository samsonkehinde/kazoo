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
    lager:info("Found callflows: ~p", [Results]),

    case length(Results) > 0 of
        true ->
            %% send the call to the first callflow found.
            [{Id, Cf}|_] = Results,
            lager:info("found callflow ~s for number ~s", [Id, Number]),
            cf_exe:continue_with_flow(Cf, Call);
        false ->
            lager:info("no callflow found for number ~s", [Number]),
            cf_exe:continue(Call)
    end.

find_in_account(AccountId, Number) ->
    lager:info("Search for callflows number ~p in account ~p", [Number, AccountId]),
    Db = kz_util:format_account_db(AccountId),
    case kz_datamgr:get_results(Db, <<"callflows/listing_by_number">>,[{key, Number}, include_docs]) of
        {ok, Callflows} ->
            lists:foldl(
              fun(Doc, Acc) ->
                    CF = kz_json:get_value([<<"doc">>, <<"flow">>], Doc),
                    ID = kz_json:get_value([<<"doc">>, <<"_id">>], Doc),
                    lager:debug("Callflow : ~p", [CF]),
                    [{ID, CF} | Acc]
              end, [], Callflows);
        {error, _} ->
            []
    end.