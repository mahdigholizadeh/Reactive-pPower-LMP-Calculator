function [] = ALMPANDRLMP()
%mahdigholizadeh 
% First Revsion : 8/6/2026 20:50 REV001
% Last Revsion : 8/11/2026 13:00 REV016
% =========================================================================
% STEP 1: USE MATPOWER TO GENERATE STOCHASTIC RLMP DATA
% =========================================================================
clc;close all;
mpc_base = loadcase('case39_gh'); 

define_constants;

PD=PD; QD=QD; BUS_AREA=BUS_AREA; BUS_I=BUS_I; PF=PF; PT=PT; RATE_A=RATE_A;
F_BUS=F_BUS; T_BUS=T_BUS; LAM_P=LAM_P; LAM_Q=LAM_Q;

fprintf('Case loaded: %d buses, %d branches, %d generators.\n', ...
    size(mpc_base.bus,1), size(mpc_base.branch,1), size(mpc_base.gen,1));
% --- 1.1. Map Bus Base kV to Branch 'From' and 'To' Buses ---
% Use 'ismember' to safely map Bus IDs to their row indices in mpc_base.bus
[~, f_idx] = ismember(mpc_base.branch(:, F_BUS), mpc_base.bus(:, BUS_I));
[~, t_idx] = ismember(mpc_base.branch(:, T_BUS), mpc_base.bus(:, BUS_I));

% Extract Base kV for 'From' bus and 'To' bus for every branch
f_kv = mpc_base.bus(f_idx, BASE_KV);
t_kv = mpc_base.bus(t_idx, BASE_KV);

% Define branch voltage level (takes higher voltage side for transformers)
branch_base_kv = max(f_kv, t_kv);

% --- 1.2. Identify Unlimited Lines (RATE_A == 0) ---
unlimited_lines = (mpc_base.branch(:, RATE_A) == 0);

% --- 1.3. Define Rating Lookup Table [Base_kV, RATE_A, RATE_B, RATE_C] ---
% Format: [Voltage_kV, Rate_A_MVA, Rate_B_MVA, Rate_C_MVA]
ratings_table = [
    765.0,  4000.0,  4400.0,  4800.0;  % 6-bundle Chukar / 4-bundle 765 kV EHV corridor
    500.0,  2200.0,  2420.0,  2640.0;  % 4-bundle Curlew / Rail 500 kV EHV line
    345.0,  1200.0,  1320.0,  1440.0;  % 2-bundle Cardinal 345 kV line
    230.0,   650.0,   715.0,   780.0;  % Twin-bundle Drake 230 kV HV line
    161.0,   400.0,   440.0,   480.0;  % Heavy single/twin 161 kV HV line
    138.0,   300.0,   330.0,   360.0;  % Standard 138 kV single-conductor line
    115.0,   200.0,   220.0,   240.0;  % Standard 115 kV sub-transmission line
     86.0,   100.0,   110.0,   120.0;  % 86 kV sub-transmission line
     66.0,    75.0,    82.5,    90.0;  % 66 kV sub-transmission line
     20.0,    20.0,    22.0,    24.0;  % 20 kV primary distribution feeder (~600 A)
     13.8,    12.0,    13.2,    14.4;  % 13.8 kV primary distribution feeder (~500 A)
      6.6,     6.0,     6.6,     7.2;  % 6.6 kV industrial distribution feeder
      2.3,     2.0,     2.2,     2.4;  % 2.3 kV plant feeder cable
      1.1,     1.0,     1.1,     1.2;  % 2.3 kV plant feeder cable
      0.6,     0.8,     0.88,    0.96; % 600 V low-voltage feeder / busway
];

% --- 1.4. Apply Thermal Limits to Unlimited Branches ---
updated_count = 0;

for k = 1:size(ratings_table, 1)
    target_kv = ratings_table(k, 1);
    rate_a    = ratings_table(k, 2);
    rate_b    = ratings_table(k, 3);
    rate_c    = ratings_table(k, 4);

    % Match unlimited branches within a 0.5 kV tolerance of target voltage
    match_mask = unlimited_lines & (abs(branch_base_kv - target_kv) < 0.5);

    % Apply ratings to RATE_A, RATE_B, and RATE_C
    mpc_base.branch(match_mask, RATE_A) = rate_a;
    mpc_base.branch(match_mask, RATE_B) = rate_b;
    mpc_base.branch(match_mask, RATE_C) = rate_c;

    updated_count = updated_count + sum(match_mask);
end

fprintf('Set RATE_A, RATE_B, and RATE_C on %d previously-unlimited branches.\n', updated_count);

% --- 1.5. Generator step-up (GSU) transformers: size from connected generator capacity ---
gsu_kv_levels = [1.0, 13.2, 13.8, 18.0, 20.0, 22.0, 24.0];
is_gsu_branch = unlimited_lines & ismember(round(branch_base_kv,1), gsu_kv_levels);
gsu_idx = find(is_gsu_branch);

headroom = 1.25;  % 25% headroom above nameplate PMAX
n_sized = 0;
for bi = gsu_idx'
    if mpc_base.bus(f_idx(bi), BASE_KV) < mpc_base.bus(t_idx(bi), BASE_KV)
        term_bus = mpc_base.branch(bi, F_BUS);
    else
        term_bus = mpc_base.branch(bi, T_BUS);
    end
    gens_here = mpc_base.gen(:, GEN_BUS) == term_bus;
    if any(gens_here)
        cap = sum(mpc_base.gen(gens_here, PMAX));
        rate = max(headroom * cap, 10);  % floor of 10 MVA for tiny/auxiliary units
        mpc_base.branch(bi, RATE_A) = rate;
        mpc_base.branch(bi, RATE_B) = rate * 1.1;
        mpc_base.branch(bi, RATE_C) = rate * 1.2;
        n_sized = n_sized + 1;
    end
end
fprintf('Sized %d GSU transformer branches from connected generator capacity.\n', n_sized);

still_unlimited = mpc_base.branch(:, RATE_A) == 0;
fprintf('Branches still unrated after both passes: %d\n', sum(still_unlimited));
if any(still_unlimited)
    % Fallback for any leftovers: natural-flow + headroom (same method used for case300)
    mpc_ref = mpc_base;
    mpc_ref.branch(still_unlimited, RATE_A) = 0;
    mpopt_ref = mpoption('model','AC','opf.ac.solver','MIPS','verbose',0,'out.all',0);
    ref_results = runopf(mpc_ref, mpopt_ref);
    if ref_results.success
        natural_flow = max(abs(ref_results.branch(:,PF)), abs(ref_results.branch(:,PT)));
        rate_fallback = max(1.5 * natural_flow(still_unlimited), 10);
        mpc_base.branch(still_unlimited, RATE_A) = rate_fallback;
        mpc_base.branch(still_unlimited, RATE_B) = rate_fallback * 1.1;
        mpc_base.branch(still_unlimited, RATE_C) = rate_fallback * 1.2;
        fprintf('Sized remaining %d branches via natural-flow headroom fallback.\n', sum(still_unlimited));
    else
        warning('Reference OPF for fallback sizing failed — %d branches remain unrated.', sum(still_unlimited));
    end
end


% --- 1.6. Merge parallel/duplicate branches (same bus pair) into one equivalent ---
fromto = mpc_base.branch(:, [F_BUS T_BUS]);
[sorted_pairs, ~] = sort(fromto, 2);
[unique_pairs, ~, ic] = unique(sorted_pairs, 'rows');
dup_groups = find(accumarray(ic, 1) > 1);

rows_to_remove = [];
for g = dup_groups'
    idx = find(ic == g);   % row indices of this duplicate pair in mpc_base.branch
    fprintf('Merging %d parallel branches between bus %d and bus %d\n', ...
        length(idx), unique_pairs(g,1), unique_pairs(g,2));

    % Parallel admittance combination: Y_eq = sum(Y_k), then convert back to Z
    Z = complex(mpc_base.branch(idx, BR_R), mpc_base.branch(idx, BR_X));
    Y_eq = sum(1 ./ Z);
    Z_eq = 1 / Y_eq;

    B_eq = sum(mpc_base.branch(idx, BR_B));      % line charging susceptances add
    RATE_eq = sum(mpc_base.branch(idx, RATE_A)); % thermal ratings add in parallel

    % Write merged values into the first branch of the group
    keep = idx(1);
    mpc_base.branch(keep, BR_R) = real(Z_eq);
    mpc_base.branch(keep, BR_X) = imag(Z_eq);
    mpc_base.branch(keep, BR_B) = B_eq;
    mpc_base.branch(keep, RATE_A) = RATE_eq;
    if size(mpc_base.branch, 2) >= RATE_C
        mpc_base.branch(keep, RATE_B) = RATE_eq;
        mpc_base.branch(keep, RATE_C) = RATE_eq;
    end

    % Mark the rest of the group for deletion
    rows_to_remove = [rows_to_remove; idx(2:end)];
end
mpc_base.branch(rows_to_remove, :) = [];
fprintf('Removed %d redundant parallel-branch rows (merged into equivalents).\n', ...
    length(rows_to_remove));

% --- 1.7. Fix INVERTED generator/voltage bounds (max < min), not just degenerate ones ---
p_inverted = mpc_base.gen(:,PMAX) < mpc_base.gen(:,PMIN);
q_inverted = mpc_base.gen(:,QMAX) < mpc_base.gen(:,QMIN);
v_inverted = mpc_base.bus(:,VMAX) < mpc_base.bus(:,VMIN);

if any(p_inverted) || any(q_inverted) || any(v_inverted)
    fprintf('WARNING: inverted bounds — %d gen P, %d gen Q, %d bus V. Swapping.\n', ...
        sum(p_inverted), sum(q_inverted), sum(v_inverted));
    tmp = mpc_base.gen(p_inverted, PMAX);
    mpc_base.gen(p_inverted, PMAX) = mpc_base.gen(p_inverted, PMIN);
    mpc_base.gen(p_inverted, PMIN) = tmp;
    tmp = mpc_base.gen(q_inverted, QMAX);
    mpc_base.gen(q_inverted, QMAX) = mpc_base.gen(q_inverted, QMIN);
    mpc_base.gen(q_inverted, QMIN) = tmp;
    tmp = mpc_base.bus(v_inverted, VMAX);
    mpc_base.bus(v_inverted, VMAX) = mpc_base.bus(v_inverted, VMIN);
    mpc_base.bus(v_inverted, VMIN) = tmp;
end

% --- 1.8 Widen any degenerate (zero-width) generator/voltage bounds ---
eps_p = 1e-3; eps_q = 1e-3; eps_v = 1e-3;

pmax_eq_pmin = (mpc_base.gen(:,PMAX) - mpc_base.gen(:,PMIN)) < eps_p;
mpc_base.gen(pmax_eq_pmin, PMAX) = mpc_base.gen(pmax_eq_pmin, PMAX) + eps_p;
mpc_base.gen(pmax_eq_pmin, PMIN) = mpc_base.gen(pmax_eq_pmin, PMIN) - eps_p;

qmax_eq_qmin = (mpc_base.gen(:,QMAX) - mpc_base.gen(:,QMIN)) < eps_q;
mpc_base.gen(qmax_eq_qmin, QMAX) = mpc_base.gen(qmax_eq_qmin, QMAX) + eps_q;
mpc_base.gen(qmax_eq_qmin, QMIN) = mpc_base.gen(qmax_eq_qmin, QMIN) - eps_q;

vmax_eq_vmin = (mpc_base.bus(:,VMAX) - mpc_base.bus(:,VMIN)) < eps_v;
mpc_base.bus(vmax_eq_vmin, VMAX) = mpc_base.bus(vmax_eq_vmin, VMAX) + eps_v;
mpc_base.bus(vmax_eq_vmin, VMIN) = mpc_base.bus(vmax_eq_vmin, VMIN) - eps_v;

fprintf('Widened %d gen P-bounds, %d gen Q-bounds, %d bus V-bounds.\n', ...
    sum(pmax_eq_pmin), sum(qmax_eq_qmin), sum(vmax_eq_vmin));

% =========================================================================
% STEP 2: SOLVER OPTIONS TUNED FOR SYSTEM
% =========================================================================
mpopt = mpoption('model', 'AC', ...
    'pf.alg', 'NR', ...
    'pf.current_balance', 0, ...
    'pf.v_cartesian', 2, ...
    'pf.tol', 1e-8, ...
    'pf.gs.max_it', 1000, ...
    'pf.radial.vcorr', 1, ...
    'pf.radial.vcorr', 1, ...
    'pf.enforce_q_lims', 2, ...
    'cpf.parameterization', 3, ...
    'cpf.stop_at', 'FULL', ...
    'cpf.enforce_p_lims', 1, ...
    'cpf.enforce_q_lims', 1, ...
    'cpf.enforce_v_lims', 1, ...
    'cpf.enforce_flow_lims', 1, ...
    'cpf.step', 0.001, ...
    'cpf.adapt_step', 1, ...
    'cpf.step_min', 1e-6, ...
    'cpf.step_max', 0.005, ...
    'cpf.adapt_step_damping', 0.1, ...
    'cpf.adapt_step_tol', 1e-6, ...
    'cpf.target_lam_tol', 1e-8, ...
    'cpf.nose_tol', 1e-8, ...
    'cpf.p_lims_tol', 0.001, ...
    'cpf.q_lims_tol', 0.001, ...
    'cpf.v_lims_tol', 1e-6, ...
    'cpf.flow_lims_tol', 0.001, ...
    'cpf.plot.level', 1, ...
    'cpf.plot.bus', 1, ...
    'opf.ac.solver', 'MIPS', ...
    'opf.current_balance', 1, ...
    'opf.v_cartesian', 0, ...
    'opf.violation', 1e-6, ...
    'opf.use_vg', 0.5, ...
    'opf.flow_lim', 'S', ...
    'opf.ignore_angle_lim', 1, ...
    'opf.softlims.default', 1, ...
    'opf.start', 2, ...%edited from 0 to 2 : warm-start AC OPF from DC OPF solution
    'opf.return_raw_der', 1, ...
    'verbose', 0, ...
    'mips.linsolver', '', ...
    'mips.feastol', 1e-6, ...
    'mips.gradtol', 1e-6, ...
    'mips.comptol', 1e-6, ...
    'mips.costtol', 1e-6, ...
    'mips.max_it', 5000, ...
    'mips.step_control', 0, ...
    'mips.sc.red_it', 20, ...
    'mips.xi', 0.9995, ...
    'mips.sigma', 0.1, ...
    'mips.z0', 1, ...
    'mips.alpha_min', 1e-7, ...
    'mips.rho_min', 0.95, ...
    'mips.rho_max', 1.05, ...
    'mips.mu_threshold', 1e-6, ...
    'mips.max_stepsize', 1e10, ...
    'out.all', 0);

% =========================================================================
% STEP 4: SCENARIO / NODE-SET CONFIGURATION
% =========================================================================
num_scenarios = 50000; % Number of operating points to simulate

% --- Off-peak / peak load scaling ---
mid_peak    = 0.85;   % typical daily-average loading fraction of annual peak
delta_peak  = 0.15;   % off-peak ~0.70, peak ~1.00 of system design load
spread      = 0.05;   % per-scenario random variation
area_spread = 0.05;   % additional per-AREA random variation (spatial heterogeneity)

areas = unique(mpc_base.bus(:, BUS_AREA));
n_areas = length(areas);

circuit_breaker = 2;   % 0 = auto-detect bus once, then fix it for production run
                        % 1 = re-select congested bus dynamically every iteration
                        % 2 = keep the manually-set default bus_idx, no auto-detection at all
exploration_scenarios = 30;   % only used when circuit_breaker == 0

bus_idx = 8; % Default bus for analysis

% --- Multi-node configuration
% node_set: up to 5 bus ROW indices tracked individually every iteration,
% in addition to the single bus_idx and the whole-system average.
node_set_size = 5;
node_set = [3 4 7 20 24];   % filled by exploration below, or set manually, e.g. [4 120 356 892 1500]

% =========================================================================
% STEP 5: EXPLORATION PASS — pick bus_idx (mode 0) and node_set (top-5 congested)
% =========================================================================

if circuit_breaker == 0 || isempty(node_set)
    fprintf('\n=== Exploration: %d scenarios to find congested buses ===\n', exploration_scenarios);
    explore_bus_history = nan(exploration_scenarios, 1);
    explore_bus_freq = containers.Map('KeyType', 'double', 'ValueType', 'double');

    for e = 1:exploration_scenarios
        mpc_explore = mpc_base;
        sf = 1.0 + 0.05 * rand();   % push right up to / slightly above design peak
        mpc_explore.bus(:, PD) = mpc_explore.bus(:, PD) * sf;
        mpc_explore.bus(:, QD) = mpc_explore.bus(:, QD) * sf;

        r = runopf(mpc_explore, mpopt);
        if r.success
            flow_e = max(abs(r.branch(:, PF)), abs(r.branch(:, PT)));
            limits_e = r.branch(:, RATE_A);
            congested_e = (limits_e > 0) & (flow_e >= 0.98 * limits_e);
            if any(congested_e)
                buses_e = [r.branch(congested_e, F_BUS); r.branch(congested_e, T_BUS)];
                for b = buses_e'
                    if isKey(explore_bus_freq, b)
                        explore_bus_freq(b) = explore_bus_freq(b) + 1;
                    else
                        explore_bus_freq(b) = 1;
                    end
                end
                [u, ~, ic2] = unique(buses_e);
                counts = accumarray(ic2, 1);
                [~, mpos] = max(counts);
                explore_bus_history(e) = find(mpc_base.bus(:, BUS_I) == u(mpos), 1);
            end
        end
        fprintf('Exploration %d/%d\n', e, exploration_scenarios);
    end

    % Fix bus_idx for mode 0
    if circuit_breaker == 0
        valid_explore = explore_bus_history(~isnan(explore_bus_history));
        if ~isempty(valid_explore)
            bus_idx = mode(valid_explore);
            fprintf('Auto-selected bus_idx = %d (most frequently congested).\n', bus_idx);
        else
            fprintf('No congestion in exploration — keeping default bus_idx = %d.\n', bus_idx);
        end
    end

    % Build node_set from top-5 most frequently congested buses (by ID)
    if isempty(node_set)
        if explore_bus_freq.Count > 0
            keys_arr = cell2mat(keys(explore_bus_freq));
            vals_arr = cell2mat(values(explore_bus_freq));
            [~, order] = sort(vals_arr, 'descend');
            top_ids = keys_arr(order(1:min(node_set_size, length(order))));
            node_set = arrayfun(@(id) find(mpc_base.bus(:,BUS_I) == id, 1), top_ids);
        else
            node_set = bus_idx;  % fallback: single node only
        end
        fprintf('Auto-selected node_set (row idx) = %s\n', mat2str(node_set));
    end
end
n_nodes = length(node_set);

% =========================================================================
% STEP 6: PREALLOCATE (sliced arrays required for loop)
% =========================================================================
% Pre-allocate arrays
ALMP_raw_off  = nan(num_scenarios, 1);
ALMP_raw_peak = nan(num_scenarios, 1);
RLMP_raw_off  = nan(num_scenarios, 1);
RLMP_raw_peak = nan(num_scenarios, 1);

% Multi-node matrices: rows = scenario, cols = node in node_set
ALMP_node_off  = nan(num_scenarios, n_nodes);
ALMP_node_peak = nan(num_scenarios, n_nodes);
RLMP_node_off  = nan(num_scenarios, n_nodes);
RLMP_node_peak = nan(num_scenarios, n_nodes);

% System-average (mean across ALL buses) per scenario
ALMP_sysavg_off  = nan(num_scenarios, 1);
ALMP_sysavg_peak = nan(num_scenarios, 1);
RLMP_sysavg_off  = nan(num_scenarios, 1);
RLMP_sysavg_peak = nan(num_scenarios, 1);

scale_factor_off_hist  = nan(num_scenarios, 1);
scale_factor_peak_hist = nan(num_scenarios, 1);

congested_bus_history = nan(num_scenarios, 1);
bus_idx_history        = nan(num_scenarios, 1);
congested_lines_info   = cell(num_scenarios, 1);  % preallocated for loop

fprintf('\nRunning MATPOWER AC OPF for %d scenarios (parallel)...\n', num_scenarios);
t_start = tic;

% 3. Main production loop 
for i = 1:num_scenarios
    mpc = mpc_base;
    mpc_off = mpc;
    mpc_peak = mpc;
    
    % --- Spatially  off-peak/peak scaling per area  ---
    random_load = rand();
    base_sf_off  = (mid_peak - delta_peak) + spread * (2*random_load - 1);
    base_sf_peak = (mid_peak + delta_peak) + spread * (2*random_load - 1);

    area_factors_off  = 1 + area_spread * (2*rand(n_areas,1) - 1);
    area_factors_peak = 1 + area_spread * (2*rand(n_areas,1) - 1);

    %Total Generation Capacity ~9,966 MW maximum real power output available
    %Total System Load ~4,242 MW (Active Power) and ~1,438 MVAr (Reactive Power)

    mpc_off.bus(:, PD) = mpc_off.bus(:, PD) * base_sf_off;
    mpc_off.bus(:, QD) = mpc_off.bus(:, QD) * base_sf_off;

    mpc_peak.bus(:, PD) = mpc_peak.bus(:, PD) * base_sf_peak; 
    mpc_peak.bus(:, QD) = mpc_peak.bus(:, QD) * base_sf_peak;

    pd_off  = mpc_off.bus(:, PD);
    qd_off  = mpc_off.bus(:, QD);
    pd_peak = mpc_peak.bus(:, PD);
    qd_peak = mpc_peak.bus(:, QD);
    bus_area = mpc_base.bus(:, BUS_AREA);

    for a = 1:n_areas
        mask = (bus_area == areas(a));
        pd_off(mask)  = pd_off(mask)  * base_sf_off  * area_factors_off(a);
        qd_off(mask)  = qd_off(mask)  * base_sf_off  * area_factors_off(a);
        pd_peak(mask) = pd_peak(mask) * base_sf_peak * area_factors_peak(a);
        qd_peak(mask) = qd_peak(mask) * base_sf_peak * area_factors_peak(a);
    end
    mpc_off.bus(:, PD) = pd_off;
    mpc_off.bus(:, QD) = qd_off;
    mpc_peak.bus(:, PD) = pd_peak;
    mpc_peak.bus(:, QD) = qd_peak;

    scale_factor_off_hist(i)  = base_sf_off;
    scale_factor_peak_hist(i) = base_sf_peak;

    results_off = runopf(mpc_off, mpopt);
    results_peak = runopf(mpc_peak, mpopt);
    
    if results_off.success && results_peak.success
        % --- Single-node (bus_idx) extraction ---
        local_bus_idx = bus_idx;

        % --- Congestion detection (peak case) ---
        flow_peak = max(abs(results_peak.branch(:, PF)), abs(results_peak.branch(:, PT)));
        limits_peak = results_peak.branch(:, RATE_A);
        is_congested = (limits_peak > 0) & (flow_peak >= 0.98 * limits_peak);
        congested_branch_idx = find(is_congested);

        local_congested_bus = NaN;
        if ~isempty(congested_branch_idx)
            congested_buses = [results_peak.branch(congested_branch_idx, F_BUS); ...
                                results_peak.branch(congested_branch_idx, T_BUS)];
            [unique_buses, ~, ic3] = unique(congested_buses);
            bus_counts = accumarray(ic3, 1);
            [~, max_pos] = max(bus_counts);
            candidate_bus_id = unique_buses(max_pos);
            local_congested_bus = find(mpc_base.bus(:, BUS_I) == candidate_bus_id, 1);

            congested_lines_info{i} = struct('iter', i, 'branches', congested_branch_idx, ...
                'flow', flow_peak(congested_branch_idx), 'limit', limits_peak(congested_branch_idx));
        end
        congested_bus_history(i) = local_congested_bus;

        if circuit_breaker == 1 && ~isnan(local_congested_bus)
            local_bus_idx = local_congested_bus;   % this-iteration-only, no cross-iter memory
        end
        bus_idx_history(i) = local_bus_idx;

        ALMP_raw_off(i)  = results_off.bus(local_bus_idx, LAM_P);
        ALMP_raw_peak(i) = results_peak.bus(local_bus_idx, LAM_P);
        RLMP_raw_off(i)  = results_off.bus(local_bus_idx, LAM_Q);
        RLMP_raw_peak(i) = results_peak.bus(local_bus_idx, LAM_Q);

        % --- Multi-node 
        ALMP_node_off(i, :)  = results_off.bus(node_set, LAM_P)';
        ALMP_node_peak(i, :) = results_peak.bus(node_set, LAM_P)';
        RLMP_node_off(i, :)  = results_off.bus(node_set, LAM_Q)';
        RLMP_node_peak(i, :) = results_peak.bus(node_set, LAM_Q)';

        % --- System-average 
        ALMP_sysavg_off(i)  = mean(results_off.bus(:, LAM_P));
        ALMP_sysavg_peak(i) = mean(results_peak.bus(:, LAM_P));
        RLMP_sysavg_off(i)  = mean(results_off.bus(:, LAM_Q));
        RLMP_sysavg_peak(i) = mean(results_peak.bus(:, LAM_Q));
    end

    fprintf('Scenario %d/%d done.\n', i, num_scenarios);
end

fprintf('\nAll scenarios complete in %.1f minutes.\n', toc(t_start)/60);

% 4. Guard the post-loop auto-select summary — skip for mode 2
if circuit_breaker ~= 2
    valid_congested = congested_bus_history(~isnan(congested_bus_history));
    if ~isempty(valid_congested)
        bus_idx = mode(valid_congested);
        fprintf('Auto-selected bus_idx = %d (most frequently congested bus)\n', bus_idx);
    else
        fprintf('No congestion detected in any scenario — keeping default bus_idx = %d\n', bus_idx);
    end
else
    fprintf('Circuit breaker = 2: kept fixed bus_idx = %d throughout (no auto-selection).\n', bus_idx);
end

valid_congested = congested_bus_history(~isnan(congested_bus_history));
if ~isempty(valid_congested)
    bus_idx = mode(valid_congested);   % most frequently congested bus across all scenarios
    fprintf('Auto-selected bus_idx = %d (most frequently congested bus)\n', bus_idx);
else
    fprintf('No congestion detected in any scenario — keeping default bus_idx = %d\n', bus_idx);
end

% =========================================================================
% STEP 7: VALIDITY FILTER
% =========================================================================
valid_idx = ~isnan(ALMP_raw_off) & ~isnan(ALMP_raw_peak);
fprintf('Valid converged scenarios: %d / %d\n', sum(valid_idx), num_scenarios);

ALMP_off  = ALMP_raw_off(valid_idx);
ALMP_peak = ALMP_raw_peak(valid_idx);
RLMP_off  = RLMP_raw_off(valid_idx);
RLMP_peak = RLMP_raw_peak(valid_idx);

ALMP_node_off_v  = ALMP_node_off(valid_idx, :);
ALMP_node_peak_v = ALMP_node_peak(valid_idx, :);
RLMP_node_off_v  = RLMP_node_off(valid_idx, :);
RLMP_node_peak_v = RLMP_node_peak(valid_idx, :);

ALMP_sysavg_off_v  = ALMP_sysavg_off(valid_idx);
ALMP_sysavg_peak_v = ALMP_sysavg_peak(valid_idx);
RLMP_sysavg_off_v  = RLMP_sysavg_off(valid_idx);
RLMP_sysavg_peak_v = RLMP_sysavg_peak(valid_idx);

sf_off_v  = scale_factor_off_hist(valid_idx);
sf_peak_v = scale_factor_peak_hist(valid_idx);

min_required = 10;
if sum(valid_idx) < min_required
    warning('Only %d valid scenario(s) — skipping statistics/plots (need >= %d).', sum(valid_idx), min_required);
    return;
end

% =========================================================================
% STEP 8: SINGLE-NODE STATISTICS
% =========================================================================
min_required = 100;

if length(ALMP_off) < min_required
    warning('Only %d valid scenario(s) — skipping statistical analysis (need >= %d).', ...
        length(ALMP_off), min_required);
else 
    % Calculate Moments for offpeak
    fprintf('--- ALMP off-peak Statistical Moments ---\n');
    fprintf('Mean:     %.4f\n', mean(ALMP_off));
    fprintf('Std Dev:  %.4f\n', std(ALMP_off));
    fprintf('Skewness: %.4f\n', skewness(ALMP_off));
    fprintf('Kurtosis: %.4f\n\n', kurtosis(ALMP_off));
    
    fprintf('--- RLMP off-peak Statistical Moments ---\n');
    fprintf('Mean:     %.4f\n', mean(RLMP_off));
    fprintf('Std Dev:  %.4f\n', std(RLMP_off));
    fprintf('Skewness: %.4f\n', skewness(RLMP_off));
    fprintf('Kurtosis: %.4f\n\n', kurtosis(RLMP_off));

    % Calculate Moments for peak
    fprintf('--- ALMP peak Statistical Moments ---\n');
    fprintf('Mean:     %.4f\n', mean(ALMP_peak));
    fprintf('Std Dev:  %.4f\n', std(ALMP_peak));
    fprintf('Skewness: %.4f\n', skewness(ALMP_peak));
    fprintf('Kurtosis: %.4f\n\n', kurtosis(ALMP_peak));
    
    fprintf('--- RLMP peak Statistical Moments ---\n');
    fprintf('Mean:     %.4f\n', mean(RLMP_peak));
    fprintf('Std Dev:  %.4f\n', std(RLMP_peak));
    fprintf('Skewness: %.4f\n', skewness(RLMP_peak));
    fprintf('Kurtosis: %.4f\n\n', kurtosis(RLMP_peak));
    % Calculate Correlation
    [R_matrix_off, P_value_off] = corrcoef(ALMP_off, RLMP_off);
    correlation_coeff_off = R_matrix_off(1,2);
    fprintf('Pearson Correlation between ALMP and RLMP in off-peak: %.4f\n', correlation_coeff_off);
    
    % Calculate Correlation
    [R_matrix_peak, P_value_peak] = corrcoef(ALMP_peak, RLMP_peak);
    correlation_coeff_peak = R_matrix_peak(1,2);
    fprintf('Pearson Correlation between ALMP and RLMP peak: %.4f\n', correlation_coeff_peak);
end

%  Plotting the 6 Visualizations

f1 = figure('Name', 'ALMP and RLMP Stochastic Analysis', 'Position', [100, 100, 1200, 800]);

histogram_number = 100;
linespace_number = 2000;
scatter_size = 10;


% Plot 1: RLMP off-peak Histogram vs Normal Distribution
subplot(2, 2, 1);
RLMP_off_plot = filter_outliers(RLMP_off, 3);
histogram(RLMP_off_plot, histogram_number, 'Normalization', 'pdf', 'FaceColor', '#D95319', 'EdgeColor', 'w'); hold on;
x_rlmp = linspace(min(RLMP_off_plot), max(RLMP_off_plot), 2000);
plot(x_rlmp, normpdf(x_rlmp, mean(RLMP_off_plot), std(RLMP_off_plot)), 'k-', 'LineWidth', 2);
title('1. RLMP off dist. vs Normal dist. (25st-75th pctl)');
xlabel('RLMP ($/MVArh)');
ylabel('Probability Density');
legend('Empirical RLMP', 'Theoretical Normal', 'Location', 'best');
grid on;
% Plot 2: RLMP peak Histogram vs Normal Distribution
subplot(2, 2, 3);
RLMP_peak_plot = filter_outliers(RLMP_peak, 3);
histogram(RLMP_peak_plot, histogram_number, 'Normalization', 'pdf', 'FaceColor', '#D75319', 'EdgeColor', 'w'); hold on;
x_rlmp = linspace(min(RLMP_peak_plot), max(RLMP_peak_plot), 2000);
plot(x_rlmp, normpdf(x_rlmp, mean(RLMP_peak_plot), std(RLMP_peak_plot)), 'k-', 'LineWidth', 2);
title('2. RLMP peak dist. vs Normal dist. (25st-75th pctl)');
xlabel('RLMP ($/MVArh)');
ylabel('Probability Density');
legend('Empirical RLMP', 'Theoretical Normal', 'Location', 'best');
grid on;

% Plot 3: ALMP off-peak Histogram vs Normal Distribution
subplot(2, 2, 2);
ALMP_off_plot = filter_outliers(ALMP_off, 3);
histogram(ALMP_off_plot, histogram_number, 'Normalization', 'pdf', 'FaceColor', '#0072BD', 'EdgeColor', 'w'); hold on;
x_almp = linspace(min(ALMP_off_plot), max(ALMP_off_plot), 2000);
plot(x_almp, normpdf(x_almp, mean(ALMP_off_plot), std(ALMP_off_plot)), 'k-', 'LineWidth', 2);
title('3. ALMP off dist. vs Normal dist. (25st-75th pctl)');
xlabel('ALMP off-peak ($/MWh)');
ylabel('Probability Density');
legend('Empirical ALMP', 'Theoretical Normal', 'Location', 'best');
grid on;
% Plot 4: ALMP peak Histogram vs Normal Distribution
subplot(2, 2, 4);
ALMP_peak_plot = filter_outliers(ALMP_peak, 3);
histogram(ALMP_peak_plot, histogram_number, 'Normalization', 'pdf', 'FaceColor', '#1072BD', 'EdgeColor', 'w'); hold on;
x_almp = linspace(min(ALMP_peak_plot), max(ALMP_peak_plot), 2000);
plot(x_almp, normpdf(x_almp, mean(ALMP_peak_plot), std(ALMP_peak_plot)), 'k-', 'LineWidth', 2);
title('4. ALMP peak dist. vs Normal dist. (25st-75th pctl)');
xlabel('ALMP ($/MWh)');
ylabel('Probability Density');
legend('Empirical ALMP', 'Theoretical Normal', 'Location', 'best');
grid on;

f2 = figure('Name', 'ALMP and RLMP Stochastic Analysis', 'Position', [100, 100, 1200, 800]);

% Plot 5: Q-Q Plot of RLMP off-peak
subplot(2, 2, 1);
qqplot(RLMP_off);
title('5. Q-Q Plot of RLMP off peak');
grid on;

% Plot 6: Q-Q Plot of RLMP peak
subplot(2, 2, 3);
qqplot(RLMP_peak);
title('6. Q-Q Plot of RLMP peak');
grid on;

% Plot 7: Q-Q Plot of ALMP off-peak
subplot(2, 2, 2);
qqplot(ALMP_off);
title('7. Q-Q Plot of ALMP off peak');
grid on;

% Plot 8: Q-Q Plot of ALMP peak
subplot(2, 2, 4);
qqplot(ALMP_peak);
title('8. Q-Q Plot of ALMP peak');
grid on;

f3 = figure('Name', 'ALMP and RLMP Stochastic Analysis', 'Position', [100, 100, 1200, 800]);

% Plot 9: PDF Comparison ALMP off peak (Standardized for Scale Matching)
subplot(2, 2, 1);
Z_ALMP_off = (ALMP_off - mean(ALMP_off)) / std(ALMP_off);

Z_ALMP_off_f = filter_outliers(Z_ALMP_off, 3);

z_lo = min([Z_ALMP_off_f]);
z_hi = max([Z_ALMP_off_f]);
pts = linspace(z_lo, z_hi, linespace_number);

[f_almp_off, xi_almp_off] = ksdensity(Z_ALMP_off_f, pts);

plot(xi_almp_off, f_almp_off, 'b-', 'LineWidth', 2); hold on;
title('9. PDF Comparison ALMP off peak (Standardized, dynamic range)');
xlabel('Standardized Price off peak (Z-Score)');
ylabel('Density');
legend('ALMP off-peak PDF', 'Location', 'best');
grid on;

% Plot 10: PDF Comparison RLMP off peak (Standardized for Scale Matching)
subplot(2, 2, 3);

Z_RLMP_off = (RLMP_off - mean(RLMP_off)) / std(RLMP_off);

Z_RLMP_off_f = filter_outliers(Z_RLMP_off, 3);
z_lo = min([Z_RLMP_off_f]);
z_hi = max([Z_RLMP_off_f]);
pts = linspace(z_lo, z_hi, linespace_number);

[f_rlmp_off, xi_rlmp_off] = ksdensity(Z_RLMP_off_f, pts);

plot(xi_rlmp_off, f_rlmp_off, 'r-', 'LineWidth', 2);hold on;
title('10. PDF Comparison RLMP off peak (Standardized, dynamic range)');
xlabel('Standardized Price off peak (Z-Score)');
ylabel('Density');
legend('RLMP off peak PDF', 'Location', 'best');
grid on;

% Plot 11: PDF Comparison ALMP peak (Standardized for Scale Matching)
subplot(2, 2, 2);
Z_ALMP_peak = (ALMP_peak - mean(ALMP_peak)) / std(ALMP_peak);

Z_ALMP_peak_f = filter_outliers(Z_ALMP_peak, 3);

z_lo = min([Z_ALMP_peak_f]);
z_hi = max([Z_ALMP_peak_f]);
pts = linspace(z_lo, z_hi, linespace_number);

[f_almp_peak, xi_almp_peak] = ksdensity(Z_ALMP_peak_f, pts);

plot(xi_almp_peak, f_almp_peak, 'b-', 'LineWidth', 2); hold on;
title('11. PDF Comparison ALMP peak (Standardized, dynamic range)');
xlabel('Standardized Price (Z-Score)');
ylabel('Density');
legend('ALMP peak PDF', 'Location', 'best');
grid on;

% Plot 12: PDF Comparison RLMP (Standardized for Scale Matching)
subplot(2, 2, 4);

Z_RLMP_peak = (RLMP_peak - mean(RLMP_peak)) / std(RLMP_peak);

Z_RLMP_peak_f = filter_outliers(Z_RLMP_peak, 3);
z_lo = min([Z_RLMP_peak_f]);
z_hi = max([Z_RLMP_peak_f]);
pts = linspace(z_lo, z_hi, linespace_number);

[f_rlmp_peak, xi_rlmp_peak] = ksdensity(Z_RLMP_peak_f, pts);

plot(xi_rlmp_peak, f_rlmp_peak, 'r-', 'LineWidth', 2);hold on;
title('12. PDF Comparison RLMP peak (Standardized, dynamic range)');
xlabel('Standardized Price (Z-Score)');
ylabel('Density');
legend('RLMP peak PDF', 'Location', 'best');
grid on;

f4 = figure('Name', 'ALMP and RLMP Stochastic Analysis', 'Position', [100, 100, 1200, 800]);
% Plot 13: Correlation Scatter Plot
subplot(2, 1, 1);
scatter(ALMP_off, RLMP_off, scatter_size, 'MarkerEdgeColor', 'k', 'MarkerFaceColor', '#77AC30', 'MarkerFaceAlpha', 0.7);
hold on;
% Add a linear trendline (least squares fit)
p = polyfit(ALMP_off, RLMP_off, 1); 
x_fit_off = linspace(min(ALMP_off), max(ALMP_off), linespace_number);
y_fit_off = polyval(p, x_fit_off);
plot(x_fit_off, y_fit_off, 'r--', 'LineWidth', 2);
title(sprintf('13. Correlation off peak (R = %.4f)', correlation_coeff_off));
xlabel('ALMP off-peak ($/MWh)');
ylabel('RLMP off-peak ($/MVArh)');
legend('Data Points', 'Trendline', 'Location', 'best');
grid on;

% Plot 14: Correlation Scatter Plot
subplot(2, 1, 2);
scatter(ALMP_peak, RLMP_peak, scatter_size, 'MarkerEdgeColor', 'k', 'MarkerFaceColor', '#77AC30', 'MarkerFaceAlpha', 0.7);
hold on;
% Add a linear trendline (least squares fit)
p = polyfit(ALMP_peak, RLMP_peak, 1); 
x_fit_peak = linspace(min(ALMP_peak), max(ALMP_peak), linespace_number);
y_fit_peak = polyval(p, x_fit_peak);
plot(x_fit_peak, y_fit_peak, 'r--', 'LineWidth', 2);
title(sprintf('14. Correlation peak (R = %.4f)', correlation_coeff_peak));
xlabel('ALMP peak ($/MWh)');
ylabel('RLMP peak ($/MVArh)');
legend('Data Points', 'Trendline', 'Location', 'best');
grid on;

% =========================================================================
% STEP 9: 5-NODE STATISTICS + SELECTABLE/COMPARABLE PLOTS
% =========================================================================
report_moments = @(name, data) fprintf('%-18s Mean: %10.4f  Std: %10.4f  Skew: %8.4f  Kurt: %8.4f\n', ...
    name, mean(data), std(data), skewness(data), kurtosis(data));

node_labels = arrayfun(@(idx) sprintf('Bus %d', mpc_base.bus(idx, BUS_I)), node_set, 'UniformOutput', false);

fprintf('\n=== Per-Node Statistics (node_set) ===\n');
% --- Per-node subplots: each node gets its own auto-scaled axis ---
compare_nodes = 1:n_nodes;
n_compare = length(compare_nodes);
grid_cols = ceil(sqrt(n_compare));
grid_rows = ceil(n_compare / grid_cols);
colors = lines(n_nodes);

f_multi_off = figure('Name', 'Multi-Node RLMP Comparison — Off-Peak', 'Position', [80,80,1400,800]);
for k = 1:n_compare
    n = compare_nodes(k);
    subplot(grid_rows, grid_cols, k);
    data_f = filter_outliers(RLMP_node_off_v(:,n), 3);
    [f_kde, xi_kde] = ksdensity(data_f);
    plot(xi_kde, f_kde, 'LineWidth', 2, 'Color', colors(n,:));
    title(node_labels{n}); xlabel('RLMP ($/MVArh)'); ylabel('Density'); grid on;
end
sgtitle('RLMP Off-Peak PDF — Node Comparison (separate scales)');

f_multi_peak = figure('Name', 'Multi-Node RLMP Comparison — Peak', 'Position', [80,80,1400,800]);
for k = 1:n_compare
    n = compare_nodes(k);
    subplot(grid_rows, grid_cols, k);
    data_f = filter_outliers(RLMP_node_peak_v(:,n), 3);
    [f_kde, xi_kde] = ksdensity(data_f);
    plot(xi_kde, f_kde, 'LineWidth', 2, 'Color', colors(n,:));
    title(node_labels{n}); xlabel('RLMP ($/MVArh)'); ylabel('Density'); grid on;
end
sgtitle('RLMP Peak PDF — Node Comparison (separate scales)');

% --- Standardized overlay: z-score each node individually so they share
%     a common comparable scale — this is the actual side-by-side comparison ---
f_multi_z = figure('Name', 'Multi-Node RLMP — Standardized Overlay', 'Position', [80,80,900,700]);
subplot(2,1,1); hold on;
for n = compare_nodes
    data_f = filter_outliers(RLMP_node_off_v(:,n), 3);
    z = (data_f - mean(data_f)) / std(data_f);
    [f_kde, xi_kde] = ksdensity(z);
    plot(xi_kde, f_kde, 'LineWidth', 2, 'Color', colors(n,:), 'DisplayName', node_labels{n});
end
title('RLMP Off-Peak — Standardized Shape Comparison');
xlabel('Z-score'); ylabel('Density'); legend show; grid on;

subplot(2,1,2); hold on;
for n = compare_nodes
    data_f = filter_outliers(RLMP_node_peak_v(:,n), 3);
    z = (data_f - mean(data_f)) / std(data_f);
    [f_kde, xi_kde] = ksdensity(z);
    plot(xi_kde, f_kde, 'LineWidth', 2, 'Color', colors(n,:), 'DisplayName', node_labels{n});
end
title('RLMP Peak — Standardized Shape Comparison');
xlabel('Z-score'); ylabel('Density'); legend show; grid on;
subplot(2,1,2);
hold on;
for n = compare_nodes
    [f_kde, xi_kde] = ksdensity(RLMP_node_peak_v(:,n));
    plot(xi_kde, f_kde, 'LineWidth', 2, 'Color', colors(n,:), 'DisplayName', node_labels{n});
end
title('RLMP Peak PDF — Node Comparison');
xlabel('RLMP ($/MVArh)'); ylabel('Density'); legend show; grid on;

% =========================================================================
% STEP 10: SYSTEM-WIDE AVERAGE STOCHASTIC ANALYSIS 
% =========================================================================

fprintf('\n=== System-Average (all %d buses) Statistics ===\n', size(mpc_base.bus,1));
report_moments('ALMP off-peak (avg)', ALMP_sysavg_off_v);
report_moments('RLMP off-peak (avg)', RLMP_sysavg_off_v);
report_moments('ALMP peak (avg)',     ALMP_sysavg_peak_v);
report_moments('RLMP peak (avg)',     RLMP_sysavg_peak_v);

f_sysavg = figure('Name', 'System-Average Stochastic Analysis', 'Position', [80,80,1300,700]);
subplot(2,2,1);
ALMP_sysavg_off_plot = filter_outliers(ALMP_sysavg_off_v, 3);
histogram(ALMP_sysavg_off_plot, histogram_number, 'Normalization', 'pdf', 'FaceColor', '#0072BD'); hold on;
xg = linspace(min(ALMP_sysavg_off_plot), max(ALMP_sysavg_off_plot), linespace_number);
plot(xg, normpdf(xg, mean(ALMP_sysavg_off_plot), std(ALMP_sysavg_off_plot)), 'k-', 'LineWidth', 2);
title('System-avg ALMP off-peak (25st-75th pctl)'); xlabel('$/MWh'); ylabel('Density'); grid on;

subplot(2,2,2);
ALMP_sysavg_peak_plot = filter_outliers(ALMP_sysavg_peak_v, 3);
histogram(ALMP_sysavg_peak_plot, histogram_number, 'Normalization', 'pdf', 'FaceColor', '#1072BD'); hold on;
xg = linspace(min(ALMP_sysavg_peak_plot), max(ALMP_sysavg_peak_plot), linespace_number);
plot(xg, normpdf(xg, mean(ALMP_sysavg_peak_plot), std(ALMP_sysavg_peak_plot)), 'k-', 'LineWidth', 2);
title('System-avg ALMP peak (25st-75th pctl)'); xlabel('$/MWh'); ylabel('Density'); grid on;

subplot(2,2,3);
RLMP_sysavg_off_plot = filter_outliers(RLMP_sysavg_off_v, 3);
histogram(RLMP_sysavg_off_plot, histogram_number, 'Normalization', 'pdf', 'FaceColor', '#D95319'); hold on;
xg = linspace(min(RLMP_sysavg_off_plot), max(RLMP_sysavg_off_plot), linespace_number);
plot(xg, normpdf(xg, mean(RLMP_sysavg_off_plot), std(RLMP_sysavg_off_plot)), 'k-', 'LineWidth', 2);
title('System-avg RLMP off-peak (25st-75th pctl)'); xlabel('$/MVArh'); ylabel('Density'); grid on;

subplot(2,2,4);
RLMP_sysavg_peak_plot = filter_outliers(RLMP_sysavg_peak_v, 3);
histogram(RLMP_sysavg_peak_plot, histogram_number, 'Normalization', 'pdf', 'FaceColor', '#D75319'); hold on;
xg = linspace(min(RLMP_sysavg_peak_plot), max(RLMP_sysavg_peak_plot), linespace_number);
plot(xg, normpdf(xg, mean(RLMP_sysavg_peak_plot), std(RLMP_sysavg_peak_plot)), 'k-', 'LineWidth', 2);
title('System-avg RLMP peak (25st-75th pctl)'); xlabel('$/MVArh'); ylabel('Density'); grid on;

% =========================================================================
% STEP 11: COMPLEX-PLANE LMP ANALYSIS 
% =========================================================================

% Z = zscore(ALMP) + i * zscore(RLMP), traced in load-scale order so the
% path shows how the complex price vector evolves as load increases

zA_off  = (ALMP_off  - mean(ALMP_off))  / std(ALMP_off);
zR_off  = (RLMP_off  - mean(RLMP_off))  / std(RLMP_off);
zA_peak = (ALMP_peak - mean(ALMP_peak)) / std(ALMP_peak);
zR_peak = (RLMP_peak - mean(RLMP_peak)) / std(RLMP_peak);

Z_off  = zA_off  + 1i * zR_off;
Z_peak = zA_peak + 1i * zR_peak;

[~, order_off]  = sort(sf_off_v);
[~, order_peak] = sort(sf_peak_v);
Z_off_sorted  = Z_off(order_off);
Z_peak_sorted = Z_peak(order_peak);

f_complex = figure('Name', 'Complex-Plane LMP Analysis', 'Position', [80,80,1300,650]);

subplot(1,2,1);
scatter(real(Z_off_sorted), imag(Z_off_sorted), scatter_size, "green", "filled");
title('Off-Peak: Z = ALMP_{norm} + i \cdot RLMP_{norm}');
xlabel('Re(Z) — standardized ALMP'); ylabel('Im(Z) — standardized RLMP');
axis equal; grid on;

subplot(1,2,2);
scatter(real(Z_peak_sorted), imag(Z_peak_sorted), scatter_size, "red", "filled");
title('Peak: Z = ALMP_{norm} + i \cdot RLMP_{norm}');
xlabel('Re(Z) — standardized ALMP'); ylabel('Im(Z) — standardized RLMP');
axis equal; grid on;

% Overlay comparison — does the off-peak "shape" survive into peak?
f_complex2 = figure('Name', 'Complex-Plane LMP — Overlay', 'Position', [80,80,800,700]);

scatter(real(Z_off_sorted), imag(Z_off_sorted), scatter_size, "green", "filled"); hold on;
scatter(real(Z_peak_sorted), imag(Z_peak_sorted), scatter_size, "red", "filled");
legend('Off-peak', 'Peak', 'Location', 'best');
title('Complex-Plane LMP Trajectory: Off-Peak vs Peak');
xlabel('Re(Z) — standardized ALMP'); ylabel('Im(Z) — standardized RLMP');
axis equal; grid on;

fprintf('\nDone. Figures: multi-node comparison, system-average, complex-plane (2).\n');

end
function data_f = filter_outliers(data, k)
% Robust IQR (Tukey fence) filter — bounds are computed from the middle
% 50% of the data, so they aren't dragged around by the outliers being
% removed (unlike a percentile-count clip, which only ever removes a
% fixed number of points regardless of how many true outliers exist).
% k = 1.5 is the standard "outlier" fence; k = 3 is the wider "far out"
% fence — use k=3 first so genuine secondary congestion-price clusters
% aren't mistaken for noise and stripped out along with real outliers.
    data = data(:);
    q1 = prctile(data, 25);
    q3 = prctile(data, 75);
    iqr_val = q3 - q1;
    lo = q1 - k * iqr_val;
    hi = q3 + k * iqr_val;
    data_f = data(data >= lo & data <= hi);
end