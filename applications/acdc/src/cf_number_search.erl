-module(cf_number_search).

-export([handle/2]).

-include_lib("callflow/src/callflow.hrl").

-spec handle(kz_json:object(), kapps_call:call()) -> 'ok'.
handle(Data, Call) ->
    Number = kz_json:get_ne_binary_value(<<"number">>, Data),
    CalledNumber = kapps_call:request_user(Call),

    lager:info("Request User: ~s", [CalledNumber]),
    lager:info("Called Number: ~s", [Number]),

    Accounts = kapps_util:get_all_accounts(),

    Results = [find_in_account(Account, Number) || Account <- Accounts],

    case length(Results) > 0 of
        true ->
            %% send the call to the first callflow found.
            [CF|_] = Results,
            lager:info("found callflow ~s for number ~s", [CF, Number]),
            cf_exe:flow(CF, Call);
        false ->
            lager:info("no callflow found for number ~s", [Number]),
            cf_exe:continue(Call)
    end.

find_in_account(AccountId, Number) ->
    Db = kz_util:format_account_db(AccountId, <<"callflows">>),
    case kz_datamgr:get_results(Db, <<"_design/callflows/_view/listing">>, []) of
        {ok, Callflows} ->
            lists:foldl(
              fun(#{doc := Doc}, Acc) ->
                  Numbers = kz_json:get_value([<<"numbers">>], Doc, []),
                  case lists:member(Number, Numbers) of
                      true -> 
                        CF = kz_json:get_ne_binary_value([<<"flow">>, <<"module">>], Doc),
                        [ CF | Acc];
                      false -> Acc
                  end
              end, [], Callflows);
        {error, _} ->
            []
    end.