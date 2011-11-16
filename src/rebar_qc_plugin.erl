%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2011 Tuncer Ayaz
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------
-module(rebar_qc_plugin).

-export([quickcheck/2]).

%% ===================================================================
%% Public API
%% ===================================================================
-spec quickcheck(list(term()), term()) -> 'ok' | no_return().
quickcheck(Config, _AppFile) ->
    QCOpts = process_config(Config),
    QC = select_qc_lib(QCOpts),
    rebar_log:log(debug, "Selected QC library: ~p~n", [QC]),
    run(Config, QC, QCOpts -- [{qc_lib, QC}]).

%% ===================================================================
%% Internal functions
%% ===================================================================

-define(PROPER_MOD, proper).
-define(EQC_MOD, eqc).
-define(TEST_DIR, ".test").

process_config(Config) ->
    QCOpts = rebar_config:get(Config, qc_opts, []),
    case lists:keyfind(on_output, 1, QCOpts) of
        {_, {M, F}} ->
            lists:keyreplace(on_output, 1, QCOpts,
                            {on_output, fun(Fmt, Args) -> M:F(Fmt, Args) end});
        false ->
            QCOpts
    end.

select_qc_lib(QCOpts) ->
    case proplists:get_value(qc_lib, QCOpts) of
        undefined ->
            detect_qc_lib();
        QC ->
            case code:ensure_loaded(QC) of
                {module, QC} ->
                    QC;
                {error, nofile} ->
                    rebar_utils:abort("Configured QC library '~p' not available~n", [QC])
            end
    end.

detect_qc_lib() ->
    case code:ensure_loaded(?PROPER_MOD) of
        {module, ?PROPER_MOD} ->
            ?PROPER_MOD;
        {error, nofile} ->
            case code:ensure_loaded(?EQC_MOD) of
                {module, ?EQC_MOD} ->
                    ?EQC_MOD;
                {error, nofile} ->
                    rebar_utils:abort("No QC library available~n", [])
            end
    end.

setup_codepath() ->
    CodePath = code:get_path(),
    true = code:add_patha(rebar_utils:test_dir()),
    true = code:add_patha(rebar_utils:ebin_dir()),
    CodePath.

run(Config, QC, QCOpts) ->
    rebar_log:log(debug, "QC Options: ~p~n", [QCOpts]),

    ok = filelib:ensure_dir(filename:join(?TEST_DIR, "foo")),
    CodePath = setup_codepath(),

    %% Compile erlang code to ?TEST_DIR, using a tweaked config
    %% with appropriate defines, and include all the test modules
    %% as well.
    ok = rebar_erlc_compiler:test_compile(Config),

    {PropMods, OtherMods} = find_prop_mods(),

    maybe_init_cover(PropMods, OtherMods, Config),
    Results = lists:flatten([qc_module(QC, QCOpts, M) || M <- PropMods]),
    maybe_analyse_and_log(OtherMods, Config),
    case Results of
        [] ->
            true = code:set_path(CodePath),
            ok;
        Errors ->
            rebar_utils:abort("One or more QC properties "
                              "didn't hold true:~n~p~n", [Errors])
    end.

maybe_init_cover(PropMods, OtherMods, Config) ->
    case rebar_config:get_local(Config, cover_enabled, false) of
        true ->
            test_server_ctrl:start(),
            test_server:cover_compile({none, [], OtherMods, PropMods});
        false ->
            ok
    end.

maybe_analyse_and_log(Mods, Config) ->
    case rebar_config:get_local(Config, cover_enabled, false) of
        true ->
            CovDir = rebar_config:get_local(Config, cover_dir, ".cover"),
            Dir = filename:join(?TEST_DIR, CovDir),
            rebar_utils:ensure_dir(filename:join(Dir, "foobar")),
            Analysis = test_server:cover_analyse({details, Dir}, Mods),
            maybe_print_cover(Analysis, Config),
            test_server_ctrl:stop();
        false ->
            ok
    end.

maybe_print_cover(Analysis, Config) ->
    case rebar_config:get(Config, cover_print_enabled, false) of
        true ->
            {Mods, {Covered, NotCovered, MaxLen}} =
                lists:mapfoldl(fun collect_cover_data/2, {0, 0, 0}, Analysis),
            TotalCoverage = percentage(Covered, NotCovered),
            Width = MaxLen * -1,
            io:format("~nCode Coverage:~n", []),
            lists:foreach(fun({Mod, Pcnt}) ->
                              io:format("~*s: ~4s~n", [Width, Mod, Pcnt])
                          end, Mods),
            io:format("~n~*s : ~s~n", [Width, "Total", TotalCoverage]);
        false ->
            ok
    end.

collect_cover_data({Mod, {Cov, NotCov, _}},
                   {TotalCovered, TotalNotCovered, MaxLen}) ->
    {{Mod, percentage(Cov, NotCov)},
        {TotalCovered + Cov, TotalNotCovered + NotCov,
            erlang:max(length(atom_to_list(Mod)), MaxLen)}}.

percentage(0, 0) ->
    "not executed";
percentage(Cov, NotCov) ->
    integer_to_list(trunc((Cov / (Cov + NotCov)) * 100)) ++ "%".

qc_module(QC=eqc, QCOpts, M) -> QC:module(QCOpts, M);
qc_module(QC=_, QCOpts, M) -> QC:module(M, QCOpts).

find_prop_mods() ->
    Beams = rebar_utils:find_files(?TEST_DIR, ".*\\.beam\$"),
    AllMods = [rebar_utils:erl_to_mod(Beam) || Beam <- Beams],
    PropMods = [M || M <- AllMods, has_prop(M)],
    {PropMods, AllMods -- PropMods}.

has_prop(Mod) ->
    lists:any(fun({F,_A}) -> lists:prefix("prop_", atom_to_list(F)) end,
              Mod:module_info(exports)).
