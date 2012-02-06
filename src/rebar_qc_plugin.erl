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

-export(['check-all'/2]).
-export([quickcheck/2]).
-export(['check-specs'/2]).

%% ===================================================================
%% Public API
%% ===================================================================
-spec 'check-all'(list(term()), term()) -> 'ok' | no_return().
'check-all'(Config, _AppFile) ->
    OldCodePath = setup(Config),
    check(prop, Config, OldCodePath),
    check(spec, Config, OldCodePath),
    ok.

-spec quickcheck(list(term()), term()) -> 'ok' | no_return().
quickcheck(Config, _AppFile) ->
    check(prop, Config, setup(Config)),
    ok.

-spec 'check-specs'(list(term()), term()) -> 'ok' | no_return().
'check-specs'(Config, _AppFile) ->
    check(spec, Config, setup(Config)),
    ok.

%% ===================================================================
%% Internal functions
%% ===================================================================

-define(PROPER_MOD, proper).
-define(EQC_MOD, eqc).
-define(TEST_DIR, ".test").

check(Mode, Config, OldCodePath) ->
    QCOpts = process_config(Config, qc_opts),
    QC = select_qc_lib(QCOpts),
    rebar_log:log(debug, "Selected QC library: ~p~n", [QC]),
    run(Mode, Config, QC, QCOpts -- [{qc_lib, QC}], OldCodePath).

process_config(Config, Key) ->
    QCOpts = rebar_config:get(Config, Key, []),
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

setup(Config) ->
    ok = filelib:ensure_dir(filename:join(?TEST_DIR, "foo")),
    OldCodePath = setup_codepath(),
    TestSources = rebar_config:get_local(Config, qc_src_dir, "test"),
    TestErls = rebar_utils:find_files(TestSources, ".*\\.erl\$"),
    %% TODO: what about src_erls???
    ok = rebar_file_utils:cp_r(TestErls, ?TEST_DIR),
    ok = rebar_erlc_compiler:doterl_compile(Config, ?TEST_DIR, TestErls),
    OldCodePath.

run(Mode, Config, QC, QCOpts, OldCodePath) ->
    {PropMods, OtherMods} = find_prop_mods(),
    Results = case Mode of
        spec ->
            SpecOpts = rebar_config:get_local(Config, qc_spec_opts, QCOpts),
            rebar_log:log(debug, "QC Options: ~p~n", [SpecOpts]),
            run_qc_specs(QC, OtherMods, SpecOpts, Config);
        prop ->
            rebar_log:log(debug, "QC Options: ~p~n", [QCOpts]),
            maybe_init_cover(PropMods, OtherMods, Config),
            PropResults = run_qc_mods(QC, QCOpts, PropMods),
            maybe_analyse_and_log(OtherMods, Config),
            PropResults
    end,
    case Results of
        [] ->
            true = code:set_path(OldCodePath),
            {QC, QCOpts, OldCodePath};
        Errors ->
            rebar_utils:abort("One or more QC properties "
                              "didn't hold true:~n~p~n", [Errors])
    end.

run_qc_mods(QC, QCOpts, PropMods) ->
    lists:flatten([ qc_module(QC, QCOpts, M) || M <- PropMods ]).

run_qc_specs(QC, Mods, QCOpts, Config) ->
    ToCheck = rebar_config:get_local(Config, qc_check_specs, []),
    Results = [ qc_check_specs(QC, QCOpts, Mod) || 
                                Mod <- Mods, 
                                Rule <- ToCheck,
                                match(Mod, Rule) ],
    lists:flatten(Results).

qc_check_specs(eqc, _, _) -> 
   rebar_utils:abort("Cannot check exported function "
                     "specs using QuickCheck~n", []);
qc_check_specs(QC, QCOpts, Mod) ->
    QC:check_specs(Mod, QCOpts).

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

match(Mod, Mod) -> true;
match(Mod, Rule) when is_atom(Mod) andalso is_list(Rule) ->
    re:run(atom_to_list(Mod), Rule, [{capture, none}]) == match;
match(_, _) -> false.

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
            CovDir = rebar_config:get_local(Config, cover_dir, ".qc.cover"),
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
