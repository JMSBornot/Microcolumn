function out = izh_microcolumn_single_v3(N, M, xlsxFile, cfg)
%IZH_MICROCOLUMN_SINGLE  Single-microcolumn thalamocortical cortical model (MATLAB)
%
% out = izh_microcolumn_single_v3(N, M, xlsxFile, cfg)
%
% N        : number of cortical neurons in the microcolumn
% M        : number of incoming synapses per cortical neuron (fixed for all neurons)
% xlsxFile : path to your rewritten neuron_data.xlsx table
% cfg      : optional struct (see defaultCfg() below)
%
% Notes
% -----
% - Uses your rewritten table (ME-TYPE rows with split L2/L3 compartments and "delay" column).
% - Ignores corticocortical (CC) inputs by default.
% - Keeps thalamic/brainstem/sensory afferents as external Poisson spike sources.
% - Uses multi-compartment Izhikevich neurons (active soma + active dendrites) and compartment coupling.
% - Includes conductance-based synapses (AMPA/NMDA/GABAA/GABAB) and short-term plasticity (STP).
% - STDP is intentionally left out in this first version to keep the implementation compact/stable.
%
% Example:
%
% % Basic
% out = izh_microcolumn_single_v3(500, 80, 'neuron_data.xlsx');
% 
% % With custom settings
% cfg = struct;
% cfg.T = 2000;               % ms
% cfg.dt = 0.5;               % ms
% cfg.ignoreCC = true;        % default true
% cfg.extRatesHz.TCs = 8;     % thalamocortical specific
% cfg.extRatesHz.TCn = 2;     % thalamocortical non-specific
% cfg.extRatesHz.SENS = 0;    % baseline sensory off
% cfg.sensPulses = [500 530 80 20];  % [start end SENS_rate TCs_rate]
% out = izh_microcolumn_single_v3(800, 120, 'neuron_data.xlsx', cfg);

if nargin < 3 || isempty(xlsxFile)
    xlsxFile = 'neuron_data.xlsx';
end
if nargin < 4
    cfg = struct();
end
cfg = mergeStruct(defaultCfg(), cfg);

rng(cfg.seed);

%% 1) Load and parse your rewritten table
T = readAndCleanTable(xlsxFile);
T = T(1:42, 1:26); % mainly ready data for the cortical neurons only and TCs/TCn
meta = parseCytoarchitectonicTable(T);

%% 2) Build cortical neuron populations (soma rows = rate > 0)
net = instantiateCorticalNeurons(meta, N);

%% 3) Build synapses (M per neuron, distributed across its compartments)
[net, syn] = buildSynapses(net, meta, M, cfg);

%% 4) Simulate
sim = runSimulation(net, syn, cfg);

%% 5) Return package
out = struct();
out.cfg  = cfg;
out.meta = meta;
out.net  = net;
out.syn  = syn;
out.sim  = sim;

if cfg.doPlot
    quickPlots(out);
end

end % main function

%% ------------------------------------------------------------------------
function cfg = defaultCfg()
cfg = struct();

% Time
cfg.T  = 1000;      % ms
cfg.dt = 0.5;       % ms

% Connectivity interpretation
cfg.ignoreCC = true;
cfg.useNSForCompartmentAllocation = true;   % allocate M across compartments using NS weights
cfg.reweightSrcPctByNS = true;             % reweight srcPct across compartments using NS (global)

% External afferents (Poisson rates, per synapse)
cfg.extRatesHz = struct( ...
    'TCs',   5.0, ...
    'TCn',   2.0, ...
    'Tis',   2.0, ...
    'Tin',   2.0, ...
    'TRN',   3.0, ...
    'BSTEM', 1.0, ...
    'SENS',  0.0);

% Optional sensory pulse train (applies to SENS and TCs rates)
% each row: [tStart_ms, tEnd_ms, sensRateHz, tcsRateHz]
cfg.sensPulses = [];    % e.g., [200 230 80 20; 600 630 80 20]

% Synaptic kinetics time constants (ms)
cfg.tauAMPA  = 5;
cfg.tauNMDA  = 150;
cfg.tauGABAA = 6;
cfg.tauGABAB = 150;

% Conductance split per event
cfg.fracAMPA = 0.8;
cfg.fracNMDA = 0.2;
cfg.fracGABAA = 0.8;
cfg.fracGABAB = 0.2;

% Reversal potentials (mV)
cfg.Eexc   = 0;
cfg.EgabaA = -70;
cfg.EgabaB = -90;

% Initial weights
cfg.excWInitMax = 6.0;   % paper-like initial excitatory conductance range [0,6]
cfg.inhWFixed   = 4.0;   % paper-like fixed GABAergic conductance
cfg.tcWeightScale = 1.5; % thalamic/sensory can be stronger (tunable)

% Optional direct current injection to selected populations (pA)
% format: struct with fields by population base-name, scalar current (e.g., cfg.IinjByPop.p4 = 50)
cfg.IinjByPop = struct();

% Integration
cfg.seed = 1;
cfg.recordAllCompSpikes = false;
cfg.doPlot = true;

end

%% ------------------------------------------------------------------------
function T = readAndCleanTable(xlsxFile)
T = readtable(xlsxFile, 'VariableNamingRule','preserve');

% Keep only rows with ME-TYPE text
if ~ismember('ME-TYPE', T.Properties.VariableNames)
    error('Column "ME-TYPE" not found in %s', xlsxFile);
end

isRow = ~ismissing(string(T.("ME-TYPE")));
T = T(isRow, :);

% Drop total row
mt = string(T.("ME-TYPE"));
T = T(~strcmpi(strtrim(mt), "TOTAL NEURONS"), :);

% Remove empty helper columns and TOTAL SYNAPSIS (if present)
vars = T.Properties.VariableNames;
dropMask = false(size(vars));
for i = 1:numel(vars)
    v = string(vars{i});
    if startsWith(v, "Unnamed", 'IgnoreCase', true) || strcmpi(v, "TOTAL SYNAPSIS")
        dropMask(i) = true;
    end
end
T(:, dropMask) = [];

% Ensure numeric columns are numeric
numCols = setdiff(T.Properties.VariableNames, {'ME-TYPE'});
for i = 1:numel(numCols)
    c = numCols{i};
    if ~isnumeric(T.(c))
        T.(c) = str2double(string(T.(c)));
    end
    T.(c)(isnan(T.(c))) = 0;
end

% Normalize column names for thalamic interneuron labels (Tis/Tin variants)
vars = T.Properties.VariableNames;
if ismember('TIs', vars) && ~ismember('Tis', vars), T.Properties.VariableNames{strcmp(vars,'TIs')} = 'Tis'; end
vars = T.Properties.VariableNames;
if ismember('TIn', vars) && ~ismember('Tin', vars), T.Properties.VariableNames{strcmp(vars,'TIn')} = 'Tin'; end

% Basic checks
needed = {'ME-TYPE','rate','delay'};
for k = 1:numel(needed)
    if ~ismember(needed{k}, T.Properties.VariableNames)
        error('Required column "%s" missing in xlsx.', needed{k});
    end
end

end

%% ------------------------------------------------------------------------
function meta = parseCytoarchitectonicTable(T)
vars = T.Properties.VariableNames;
% Keep source columns in the original order
srcCols = vars;
srcCols(ismember(vars,{'ME-TYPE','rate','delay','NS'})) = [];
srcCols = srcCols(:)';

nRows = height(T);
rows = struct('name',[],'base',[],'layer',[],'rate',[],'delay',[],'NS',[],'srcPct',[]);
rows = repmat(rows, nRows, 1);

for i = 1:nRows
    rowName = char(string(T.("ME-TYPE")(i)));
    [base, layer] = splitMEType(rowName);

    rows(i).name  = rowName;
    rows(i).base  = base;
    rows(i).layer = layer;
    rows(i).rate  = T.rate(i);
    rows(i).delay = T.delay(i);
    if ismember('NS', vars)
        rows(i).NS = T.NS(i);
    else
        rows(i).NS = 0;
    end

    pct = zeros(1, numel(srcCols));
    for j = 1:numel(srcCols)
        pct(j) = T.(srcCols{j})(i);
    end
    rows(i).srcPct = pct;
end

% Group rows by base population (e.g., p4 has p4-L4,p4-L3,p4-L2,p4-L1)
baseNames = unique(string({rows.base}), 'stable');
pops = struct([]);

for p = 1:numel(baseNames)
    b = char(baseNames(p));
    idx = find(strcmp({rows.base}, b));

    % order compartments by delay ascending (soma should be delay=1)
    [~, ord] = sort([rows(idx).delay], 'ascend');
    idx = idx(ord);

    rrate = [rows(idx).rate];
    somaCandidates = find(rrate > 0);
    if isempty(somaCandidates)
        error('Population %s has no soma row (rate > 0).', b);
    end
    if numel(somaCandidates) > 1
        % keep the largest-rate row as soma if duplicated
        [~, k] = max(rrate(somaCandidates));
        somaLocal = somaCandidates(k);
    else
        somaLocal = somaCandidates;
    end

    pops(p).base = b;
    pops(p).rowIdx = idx;
    pops(p).compNames = {rows(idx).name};
    pops(p).layers    = {rows(idx).layer};
    pops(p).delaysMs  = [rows(idx).delay];
    pops(p).rates     = [rows(idx).rate];
    pops(p).NS        = [rows(idx).NS];
    pops(p).srcPct    = vertcat(rows(idx).srcPct);   % nComp x nSources
    pops(p).somaCompLocal = somaLocal;
    pops(p).somaRatePct   = rows(idx(somaLocal)).rate;
    pops(p).morphClass    = inferMorphClassFromBase(b);
    pops(p).isExcitPop    = isExcitSourceName(b);
end

meta = struct();
meta.rows = rows;
meta.pops = pops;
meta.srcCols = srcCols;

% Map source column names -> cortical population index (if cortical)
src2pop = zeros(1, numel(srcCols));
for j = 1:numel(srcCols)
    namej = srcCols{j};
    k = find(strcmp({pops.base}, namej), 1, 'first');
    if ~isempty(k)
        src2pop(j) = k;
    else
        src2pop(j) = 0;
    end
end
meta.src2pop = src2pop;

end

%% ------------------------------------------------------------------------
function [base, layer] = splitMEType(meType)
% Split by the LAST '-' only, so ss4(L2/3)-L4 works
meType = char(meType);
d = find(meType == '-', 1, 'last');
if isempty(d)
    error('ME-TYPE "%s" has no layer suffix (expected base-Lx).', meType);
end
base = strtrim(meType(1:d-1));
layer = strtrim(meType(d+1:end));
end

%% ------------------------------------------------------------------------
function m = inferMorphClassFromBase(base)
% Figure 10 morphology mapping (coarse class used for parameters)
if strcmp(base, 'nb1')
    m = 'nb1';   % LS
elseif any(strcmp(base, {'p2','p3'}))
    m = 'p23';   % RS
elseif startsWith(base, 'ss4')
    m = 'ss4';   % RS
elseif strcmp(base, 'p4')
    m = 'p4';    % RS
elseif startsWith(base, 'p5') || startsWith(base, 'p6')
    m = 'p56';   % RS (p5,p6 column in Fig. 10)
elseif startsWith(base, 'b')
    m = 'b';     % FS
elseif startsWith(base, 'nb')
    m = 'nb';    % LTS
else
    m = 'unknown';
end
end

%% ------------------------------------------------------------------------
function tf = isExcitSourceName(srcName)
% Cortical excitatory + thalamocortical + sensory/brainstem treated as excitatory here
srcName = char(srcName);
tf = startsWith(srcName, 'p') || startsWith(srcName, 'ss') || ...
     any(strcmp(srcName, {'TCs','TCn','BSTEM','SENS','CC'}));
end

%% ------------------------------------------------------------------------
function P = izhParamLibrary()
% Parameters transcribed from Fig. 10 (Supp. Materials: coarse morphology columns)
% (Values are scalar per morphology class; soma/dendrite differences handled separately)
% Data for TC, TI, and TRN not used yet.
P = struct();

P.nb1 = struct('type','LS','C',20,'k',0.3,'vr',-66,'vt',-40,'vpeakS',30,'vpeakD',100,...
               'Gup',0.6,'Gdown',2.5,'a',0.17,'b',5,'cS',-45,'cD',-45,'d',100);
P.p23 = struct('type','RS','C',100,'k',3.0,'vr',-60,'vt',-50,'vpeakS',50,'vpeakD',30,...
               'Gup',3.0,'Gdown',5.0,'a',0.01,'b',5,'cS',-60,'cD',-55,'d',400);
P.b   = struct('type','FS','C',20,'k',1.0,'vr',-55,'vt',-40,'vpeakS',25,'vpeakD',25,...
               'Gup',0.5,'Gdown',1.0,'a',0.15,'b',8,'cS',-55,'cD',-55,'d',200);
P.nb  = struct('type','LTS','C',100,'k',1.0,'vr',-56,'vt',-42,'vpeakS',40,'vpeakD',40,...
               'Gup',1.0,'Gdown',1.0,'a',0.03,'b',8,'cS',-50,'cD',-50,'d',20);
P.ss4 = struct('type','RS','C',100,'k',3.0,'vr',-60,'vt',-50,'vpeakS',50,'vpeakD',30,...
               'Gup',3.0,'Gdown',5.0,'a',0.01,'b',5,'cS',-60,'cD',-50,'d',400);
P.p4  = struct('type','RS','C',100,'k',3.0,'vr',-60,'vt',-50,'vpeakS',50,'vpeakD',50,...
               'Gup',3.0,'Gdown',5.0,'a',0.01,'b',5,'cS',-60,'cD',-50,'d',400);
P.p56 = struct('type','RS','C',100,'k',3.0,'vr',-60,'vt',-50,'vpeakS',50,'vpeakD',30,...
               'Gup',3.0,'Gdown',5.0,'a',0.01,'b',5,'cS',-60,'cD',-50,'d',400);
end

%% ------------------------------------------------------------------------
function net = instantiateCorticalNeurons(meta, N)
% Allocate N neurons across cortical populations using soma rates
pops = meta.pops;
nPop = numel(pops);

% normalize neuron population percentages
rates = [pops.somaRatePct];
rates = rates / sum(rates);

% Largest-remainder integer allocation
x = N * rates;
nPerPop = floor(x);
remN = N - sum(nPerPop);
[~, ord] = sort(x - nPerPop, 'descend');
for k = 1:remN
    nPerPop(ord(k)) = nPerPop(ord(k)) + 1;
end

% Build neurons and flattened compartment arrays
P = izhParamLibrary();

neuronPop = zeros(N,1);
neuronMorph = strings(N,1);
neuronCompStart = zeros(N,1);
neuronCompCount = zeros(N,1);
neuronSomaComp  = zeros(N,1);
neuronGup = zeros(N,1);
neuronGdown = zeros(N,1);

popNeuronIds = cell(nPop,1);

% Count total compartments first
totComp = 0;
for p = 1:nPop
    totComp = totComp + nPerPop(p) * numel(pops(p).rowIdx);
end

compNeuron = zeros(totComp,1);
compPop    = zeros(totComp,1);
compLocal  = zeros(totComp,1);
compDelayMs = zeros(totComp,1);
compIsSoma = false(totComp,1);

% Izh parameters per compartment
C = zeros(totComp,1); k = zeros(totComp,1); vr = zeros(totComp,1); vt = zeros(totComp,1);
a = zeros(totComp,1); b = zeros(totComp,1); cReset = zeros(totComp,1); dReset = zeros(totComp,1);
vpeak = zeros(totComp,1);

nid = 0;
cid = 0;
for p = 1:nPop
    base = pops(p).base;
    morph = pops(p).morphClass;
    if ~isfield(P, morph)
        error('No Izh parameter set for morphology "%s" (population %s).', morph, base);
    end
    par = P.(morph);

    ncp = numel(pops(p).rowIdx);
    ids = zeros(nPerPop(p),1);

    for j = 1:nPerPop(p)
        nid = nid + 1;
        ids(j) = nid;

        neuronPop(nid) = p;
        neuronMorph(nid) = string(morph);
        neuronCompStart(nid) = cid + 1;
        neuronCompCount(nid) = ncp;
        neuronGup(nid) = par.Gup;
        neuronGdown(nid) = par.Gdown;

        for q = 1:ncp
            cid = cid + 1;
            compNeuron(cid) = nid;
            compPop(cid)    = p;
            compLocal(cid)  = q;
            compDelayMs(cid)= pops(p).delaysMs(q);
            isSoma = (q == pops(p).somaCompLocal);
            compIsSoma(cid) = isSoma;

            C(cid)  = par.C;
            k(cid)  = par.k;
            vr(cid) = par.vr;
            vt(cid) = par.vt;
            a(cid)  = par.a;
            b(cid)  = par.b;
            dReset(cid) = par.d;

            if isSoma
                vpeak(cid)  = par.vpeakS;
                cReset(cid) = par.cS;
                neuronSomaComp(nid) = cid;
            else
                vpeak(cid)  = par.vpeakD;
                cReset(cid) = par.cD;
            end
        end
    end

    popNeuronIds{p} = ids;
end

if cid ~= totComp || nid ~= N
    error('Internal allocation error (cid=%d/%d, nid=%d/%d).', cid, totComp, nid, N);
end

net = struct();
net.N = N;
net.nPop = nPop;
net.pops = pops;
net.nPerPop = nPerPop(:);
net.popNeuronIds = popNeuronIds;

net.neuronPop = neuronPop;
net.neuronMorph = neuronMorph;
net.neuronCompStart = neuronCompStart;
net.neuronCompCount = neuronCompCount;
net.neuronSomaComp = neuronSomaComp;
net.neuronGup = neuronGup;
net.neuronGdown = neuronGdown;

net.nComp = totComp;
net.compNeuron = compNeuron;
net.compPop = compPop;
net.compLocal = compLocal;
net.compDelayMs = compDelayMs;
net.compIsSoma = compIsSoma;

net.C = C; net.k = k; net.vr = vr; net.vt = vt;
net.a = a; net.b = b; net.cReset = cReset; net.dReset = dReset; net.vpeak = vpeak;

end

%% ------------------------------------------------------------------------
function [net, syn] = buildSynapses(net, meta, M, cfg)
% Build exactly M incoming synapses per cortical neuron.
%
% For each postsynaptic neuron:
%   - split M across compartments (equal by default, or NS-weighted if enabled)
%   - for each compartment, sample source categories according to the row percentages
%   - cortical sources map to randomly chosen neurons in the microcolumn
%   - thalamic/brainstem/sensory sources are external Poisson generators

nNeurons = net.N;
pops = net.pops;
srcCols = meta.srcCols;

% First pass: estimate total synapses
totSyn = nNeurons * M;

% Preallocate
preNeuron = zeros(totSyn,1,'uint32');     % 0 for external
postComp  = zeros(totSyn,1,'uint32');
delaySteps = zeros(totSyn,1,'uint16');
isExternal = false(totSyn,1);
srcCode = zeros(totSyn,1,'uint8');        % source category code
isExcit = false(totSyn,1);
w = zeros(totSyn,1,'single');

% STP params per synapse
tauX = inf(totSyn,1);
pX   = ones(totSyn,1,'single');
x    = ones(totSyn,1,'single');

% Event routing
outgoing = cell(nNeurons,1);
externalIdx = zeros(totSyn,1,'uint32'); % collect and trim later
nExt = 0;

% Source code dictionary
srcNames = srcCols;
iCC = find(strcmp(srcNames, 'CC'), 1, 'first');  % corticocortical column (optional)

% Precompute per-population synapse source matrices and compartment weights.
% If cfg.reweightSrcPctByNS is enabled, we reweight (compartment,source) by NS and
% renormalize globally (so row-sums encode how many of the M synapses land in each compartment).
popSrcMat = cell(1, numel(pops));
popCompW  = cell(1, numel(pops));

for pp = 1:numel(pops)
    mat = pops(pp).srcPct;   % nComp x nSources (raw table values)
    ns  = pops(pp).NS(:);    % nComp x 1

    if cfg.reweightSrcPctByNS && any(ns > 0)
        % Number of "potential synapses" per (compartment,source)
        matW = (ns * ones(1, size(mat,2))) .* mat;

        % Ignore CC before normalization so it does not steal probability mass
        if cfg.ignoreCC && ~isempty(iCC)
            matW(:, iCC) = 0;
        end

        s = sum(matW(:));
        if s > 0
            matW = 100 * (matW / s);   % global percentages over all compartments
        else
            matW = mat;                % fallback
        end

        popSrcMat{pp} = matW;
        net.pops(pp).srcPctAdj = matW;

        cw = sum(matW, 2)';            % row-sum => compartment mass (in percent)
        if sum(cw) <= 0
            cw = ns(:)';               % fallback
        end
        popCompW{pp} = cw;
        net.pops(pp).compAllocW = cw;

    else
        % Legacy behavior: allocate compartments by NS (optional) and sample sources per-row.
        matU = mat;
        if cfg.ignoreCC && ~isempty(iCC)
            matU(:, iCC) = 0;
        end
        popSrcMat{pp} = matU;
        net.pops(pp).srcPctAdj = matU;

        if cfg.useNSForCompartmentAllocation && any(ns > 0)
            popCompW{pp} = ns(:)';
        else
            popCompW{pp} = ones(1, size(mat,1));
        end
        net.pops(pp).compAllocW = popCompW{pp};
    end
end

sid = 0;
for n = 1:nNeurons
    p = net.neuronPop(n);

    cStart = net.neuronCompStart(n);
    ncp    = net.neuronCompCount(n);
    compIdx = cStart + (0:ncp-1);

    % Allocate M across compartments
    allocW = popCompW{p};
    if numel(allocW) ~= ncp
        allocW = allocW(1:min(numel(allocW), ncp));
        if numel(allocW) < ncp
            allocW(end+1:ncp) = 0;
        end
    end
    if sum(allocW) <= 0
        allocW = ones(1, ncp);
    end
    allocW = allocW / sum(allocW);
    xAlloc = M * allocW;
    mComp = floor(xAlloc);
    rr = M - sum(mComp);
    [~, oo] = sort(xAlloc - mComp, 'descend');
    for k = 1:rr
        mComp(oo(k)) = mComp(oo(k)) + 1;
    end

    for q = 1:ncp
        mHere = mComp(q);
        if mHere <= 0, continue; end

        pct = popSrcMat{p}(q,:);

        % Ignore CC if requested
        if cfg.ignoreCC && ~isempty(iCC)
            pct(iCC) = 0;
        end

        if sum(pct) <= 0
            % fallback: if a row is empty, use uniform cortical sources
            pct = zeros(size(pct));
            pct(meta.src2pop > 0) = 1;
        end
        pct = pct / sum(pct);

        srcJ = sampleCategorical(pct, mHere);  % indices in srcNames

        for kk = 1:mHere
            sid = sid + 1;
            j = srcJ(kk);
            sname = srcNames{j};

            postComp(sid) = uint32(compIdx(q));
            dms = net.compDelayMs(compIdx(q));
            dly = max(1, round(dms / cfg.dt));
            delaySteps(sid) = uint16(dly);

            srcCode(sid) = uint8(j);
            ex = isExcitSourceName(sname);
            isExcit(sid) = ex;

            % Weight initialization
            if ex
                ww = cfg.excWInitMax * rand();
                if any(strcmp(sname, {'TCs','TCn','SENS','BSTEM'}))
                    ww = ww * cfg.tcWeightScale;
                end
            else
                ww = cfg.inhWFixed;
            end
            w(sid) = single(ww);

            % Assign presyn source
            popIdxSrc = meta.src2pop(j);
            if popIdxSrc > 0
                ids = net.popNeuronIds{popIdxSrc};
                if isempty(ids)
                    % If this cortical source population got 0 neurons due to rounding, convert to external surrogate
                    isExternal(sid) = true;
                    preNeuron(sid) = uint32(0);
                    nExt = nExt + 1;
                    externalIdx(nExt) = uint32(sid);
                else
                    isExternal(sid) = false;
                    preNeuron(sid) = uint32(ids(randi(numel(ids))));
                    outgoing{double(preNeuron(sid))}(end+1,1) = sid;
                end
            else
                isExternal(sid) = true;
                preNeuron(sid) = uint32(0);
                nExt = nExt + 1;
                externalIdx(nExt) = uint32(sid);
            end

            % STP parameters
            [tx, pp] = stpParamsForPair(sname, net.neuronMorph(n));
            tauX(sid) = tx;
            pX(sid)   = single(pp);
        end
    end
end

if sid ~= totSyn
    error('Synapse build mismatch (%d built, expected %d).', sid, totSyn);
end
externalIdx = externalIdx(1:nExt);

% Build external rate vector by source code
extRateHz = zeros(totSyn,1,'single');
for s = 1:totSyn
    if ~isExternal(s), continue; end
    nm = srcNames{srcCode(s)};
    hz = getExtRate(cfg.extRatesHz, nm);
    extRateHz(s) = single(hz);
end

maxDelaySteps = max(double(delaySteps));
if isempty(maxDelaySteps), maxDelaySteps = 1; end

syn = struct();
syn.M = M;
syn.nSyn = totSyn;
syn.nExt = nExt;
syn.preNeuron = preNeuron;
syn.postComp = postComp;
syn.delaySteps = delaySteps;
syn.isExternal = isExternal;
syn.srcCode = srcCode;
syn.srcNames = srcNames;
syn.isExcit = isExcit;
syn.w = w;

syn.tauX = tauX;
syn.pX   = pX;
syn.x    = x;
syn.hasStp = isfinite(tauX);

syn.outgoing = outgoing;
syn.externalIdx = externalIdx;
syn.extRateHz = extRateHz;
syn.maxDelaySteps = maxDelaySteps;

end

%% ------------------------------------------------------------------------
function hz = getExtRate(extStruct, name)
if isfield(extStruct, name)
    hz = extStruct.(name);
else
    hz = 0;
end
end

%% ------------------------------------------------------------------------
function [tauX, p] = stpParamsForPair(preName, postMorph)
% Fig. 11 simplified rules (coarse)
% postMorph is one of: nb1,p23,b,nb,ss4,p4,p56
postClass = coarsePostClass(postMorph);

if startsWith(preName,'p') || startsWith(preName,'ss')
    if any(strcmp(postClass, {'p_ss','b'}))
        tauX = 150; p = 0.6;
    elseif strcmp(postClass, 'nb')
        tauX = 100; p = 1.5;
    else
        tauX = inf; p = 1.0;
    end
elseif startsWith(preName,'b')
    if any(strcmp(postClass, {'p_ss','b'}))
        tauX = 150; p = 0.6;
    else
        tauX = inf; p = 1.0;
    end
elseif any(strcmp(preName, {'TCs','TCn'}))
    if strcmp(postClass, 'b')
        tauX = 200; p = 0.5;
    elseif strcmp(postClass, 'p_ss')
        tauX = 150; p = 0.7;
    else
        tauX = inf; p = 1.0;
    end
else
    tauX = inf; p = 1.0;
end
end

%% ------------------------------------------------------------------------
function c = coarsePostClass(morph)
if any(strcmp(morph, {'p23','ss4','p4','p56'}))
    c = 'p_ss';
elseif strcmp(morph, 'b')
    c = 'b';
elseif any(strcmp(morph, {'nb','nb1'}))
    c = 'nb';
else
    c = 'other';
end
end

%% ------------------------------------------------------------------------
function sim = runSimulation(net, syn, cfg)
dt = cfg.dt;
nSteps = round(cfg.T / dt);

nComp = net.nComp;
nNeur = net.N;

% States
v = net.vr + 5*randn(nComp,1);               % mV
u = net.b .* (v - net.vr);

gA = zeros(nComp,1,'single');
gN = zeros(nComp,1,'single');
gGi = zeros(nComp,1,'single');
gGb = zeros(nComp,1,'single');

% Optional tonic injected current by population (applied to soma only)
Iinj = zeros(nComp,1);
if isstruct(cfg.IinjByPop)
    popNames = {net.pops.base};
    f = fieldnames(cfg.IinjByPop);
    for k = 1:numel(f)
        base = f{k};
        p = find(strcmp(popNames, base), 1, 'first');
        if isempty(p), continue; end
        ids = net.popNeuronIds{p};
        Ival = cfg.IinjByPop.(base);
        Iinj(net.neuronSomaComp(ids)) = Ival;
    end
end

% Delay queue (ring buffer), each slot stores [synIdx, xeff]
Q = syn.maxDelaySteps + 1;
queue = cell(Q,1);
qPtr = 1;

% Spike recording (soma)
spikeT = zeros(100000,1);
spikeN = zeros(100000,1);
nSpk = 0;

% Optional compartment spike recording
if cfg.recordAllCompSpikes
    cSpkT = zeros(100000,1);
    cSpkC = zeros(100000,1);
    nCSpk = 0;
else
    cSpkT = []; cSpkC = []; nCSpk = 0;
end

% Precompute coupling edge lists
nEdges = max(nComp - nNeur, 0);
edgeParent = zeros(nEdges,1);
edgeChild  = zeros(nEdges,1);
edgeUpG    = zeros(nEdges,1);
edgeDnG    = zeros(nEdges,1);
eid = 0;
for n = 1:nNeur
    ch = net.neuronCompStart(n) + (0:net.neuronCompCount(n)-1);
    for q = 2:numel(ch)
        eid = eid + 1;
        edgeParent(eid) = ch(q-1);
        edgeChild(eid) = ch(q);
        edgeUpG(eid) = net.neuronGup(n);
        edgeDnG(eid) = net.neuronGdown(n);
    end
end
if eid < nEdges
    edgeParent = edgeParent(1:eid);
    edgeChild  = edgeChild(1:eid);
    edgeUpG    = edgeUpG(1:eid);
    edgeDnG    = edgeDnG(1:eid);
end

% Conductance decays
decA  = exp(-dt/cfg.tauAMPA);
decN  = exp(-dt/cfg.tauNMDA);
decGi = exp(-dt/cfg.tauGABAA);
decGb = exp(-dt/cfg.tauGABAB);

% External indices cached
extIdx = double(syn.externalIdx(:));

% STP cached indices (hot path from profile)
idxSTP = find(syn.hasStp);
stpTau = syn.tauX(idxSTP);
invTauDt = dt ./ stpTau;

% Cache sensory pulse source ids
jS = find(strcmp(syn.srcNames, 'SENS'), 1);
jT = find(strcmp(syn.srcNames, 'TCs'), 1);
extSrcCode = double(syn.srcCode(extIdx));
extIsSens = false(size(extSrcCode));
extIsTCs = false(size(extSrcCode));
if ~isempty(jS), extIsSens = (extSrcCode == jS); end
if ~isempty(jT), extIsTCs = (extSrcCode == jT); end

% Simulation main loop
for it = 1:nSteps
    tms = (it-1) * dt;

    % 1) Recover STP variables
    if ~isempty(idxSTP)
        xstp = double(syn.x(idxSTP));
        xstp = xstp + ((1 - xstp) .* invTauDt);
        xstp = min(max(xstp, 0), 5);
        syn.x(idxSTP) = single(xstp);
    end

    % 2) Decay synaptic conductances
    gA  = gA  * decA;
    gN  = gN  * decN;
    gGi = gGi * decGi;
    gGb = gGb * decGb;

    % 3) Deliver queued events for this time slot
    ev = queue{qPtr};
    queue{qPtr} = [];
    if ~isempty(ev)
        sid = ev(:,1);
        xeff = ev(:,2);

        amp = double(syn.w(sid)) .* xeff;
        pc  = double(syn.postComp(sid));
        ex  = syn.isExcit(sid);

        if any(ex)
            pce = pc(ex);
            ae  = amp(ex);
            gA  = gA  + accumarray(pce, single(cfg.fracAMPA * ae), [nComp,1], @sum, single(0));
            gN  = gN  + accumarray(pce, single(cfg.fracNMDA * ae), [nComp,1], @sum, single(0));
        end
        inh = ~ex;
        if any(inh)
            pci = pc(inh);
            ai  = amp(inh);
            gGi = gGi + accumarray(pci, single(cfg.fracGABAA * ai), [nComp,1], @sum, single(0));
            gGb = gGb + accumarray(pci, single(cfg.fracGABAB * ai), [nComp,1], @sum, single(0));
        end
    end

    % 4) External Poisson spikes (per external synapse)
    if ~isempty(extIdx)
        hzNow = double(syn.extRateHz(extIdx));

        % Optional sensory pulse overrides/additions
        if ~isempty(cfg.sensPulses)
            for r = 1:size(cfg.sensPulses,1)
                if tms >= cfg.sensPulses(r,1) && tms < cfg.sensPulses(r,2)
                    if any(extIsSens)
                        hzNow(extIsSens) = cfg.sensPulses(r,3);
                    end
                    if any(extIsTCs)
                        hzNow(extIsTCs) = cfg.sensPulses(r,4);
                    end
                end
            end
        end

        pspk = hzNow * (dt/1000);
        fireMask = rand(numel(extIdx),1) < pspk(:);

        if any(fireMask)
            sids = extIdx(fireMask);

            % STP at presynaptic spike time
            xeff = double(syn.x(sids));
            hasStp = syn.hasStp(sids);
            if any(hasStp)
                xeff(hasStp) = xeff(hasStp) .* double(syn.pX(sids(hasStp)));
                syn.x(sids(hasStp)) = single(xeff(hasStp));
            end

            dly = double(syn.delaySteps(sids));
            slots = mod((qPtr-1) + dly, Q) + 1;
            uSlots = unique(slots);
            for kk = 1:numel(uSlots)
                sl = uSlots(kk);
                m = (slots == sl);
                add = [sids(m), xeff(m)];
                if isempty(queue{sl})
                    queue{sl} = add;
                else
                    queue{sl} = [queue{sl}; add];
                end
            end
        end
    end

    % 5) Dendritic coupling current Idendr
    Idendr = zeros(nComp,1);
    if ~isempty(edgeParent)
        dvpc = v(edgeChild) - v(edgeParent);
        Idendr = Idendr + accumarray(edgeChild, edgeDnG .* dvpc, [nComp,1], @sum, 0);
        Idendr = Idendr + accumarray(edgeParent, edgeUpG .* (-dvpc), [nComp,1], @sum, 0);
    end

    % 6) Synaptic current Isyn (conductance-based)
    Bnmda = 1 ./ (1 + exp(-0.062*v)/3.57); % Mg-block sigmoid
    Isyn = double(gA) .* (v - cfg.Eexc) + ...
           double(gN) .* Bnmda .* (v - cfg.Eexc) + ...
           double(gGi).* (v - cfg.EgabaA) + ...
           double(gGb).* (v - cfg.EgabaB);

    % 7) Izhikevich integration
    I = -Idendr - Isyn + Iinj;
    dv = ( net.k .* (v - net.vr) .* (v - net.vt) - u + I ) ./ net.C;
    du = net.a .* ( net.b .* (v - net.vr) - u );

    v = v + dt * dv;
    u = u + dt * du;

    % 8) Spikes and resets
    spkComp = find(v >= net.vpeak);

    if ~isempty(spkComp)
        if cfg.recordAllCompSpikes
            need = nCSpk + numel(spkComp);
            [cSpkT, cSpkC] = growPair(cSpkT, cSpkC, need);
            cSpkT(nCSpk+1:need) = tms;
            cSpkC(nCSpk+1:need) = spkComp;
            nCSpk = need;
        end

        % Reset all spiking compartments
        v(spkComp) = net.cReset(spkComp);
        u(spkComp) = u(spkComp) + net.dReset(spkComp);

        % Propagate only soma spikes to outgoing synapses
        somaMask = net.compIsSoma(spkComp);
        if any(somaMask)
            somaSpkComp = spkComp(somaMask);
            spkNeurons = net.compNeuron(somaSpkComp);

            % record soma spikes
            need = nSpk + numel(spkNeurons);
            [spikeT, spikeN] = growPair(spikeT, spikeN, need);
            spikeT(nSpk+1:need) = tms;
            spikeN(nSpk+1:need) = spkNeurons;
            nSpk = need;

            % schedule outgoing events
            for ii = 1:numel(spkNeurons)
                npre = spkNeurons(ii);
                sids = syn.outgoing{npre};
                if isempty(sids), continue; end
                sids = double(sids(:));

                xeff = double(syn.x(sids));
                hasStp = syn.hasStp(sids);
                if any(hasStp)
                    xeff(hasStp) = xeff(hasStp) .* double(syn.pX(sids(hasStp)));
                    syn.x(sids(hasStp)) = single(xeff(hasStp));
                end

                dly = double(syn.delaySteps(sids));
                slots = mod((qPtr-1) + dly, Q) + 1;

                uSlots = unique(slots);
                for kk = 1:numel(uSlots)
                    sl = uSlots(kk);
                    m = (slots == sl);
                    add = [sids(m), xeff(m)];
                    if isempty(queue{sl})
                        queue{sl} = add;
                    else
                        queue{sl} = [queue{sl}; add];
                    end
                end
            end
        end
    end

    % 9) Advance queue pointer
    qPtr = qPtr + 1;
    if qPtr > Q, qPtr = 1; end
end

% Trim outputs
spikeT = spikeT(1:nSpk);
spikeN = spikeN(1:nSpk);
if cfg.recordAllCompSpikes
    cSpkT = cSpkT(1:nCSpk);
    cSpkC = cSpkC(1:nCSpk);
end

sim = struct();
sim.dt = dt;
sim.T = cfg.T;
sim.nSteps = nSteps;
sim.finalV = v;
sim.finalU = u;
sim.spikeTimesMs = spikeT;
sim.spikeNeurons = spikeN;
sim.nSpikes = nSpk;
sim.meanRateHz = (nSpk / net.N) / (cfg.T/1000);

if cfg.recordAllCompSpikes
    sim.compSpikeTimesMs = cSpkT;
    sim.compSpikeComps = cSpkC;
end

end

%% ------------------------------------------------------------------------
function [a1,a2] = growPair(a1,a2,need)
if need <= numel(a1), return; end
newN = max(need, ceil(1.5*numel(a1))+1000);
a1(end+1:newN,1) = 0;
a2(end+1:newN,1) = 0;
end

%% ------------------------------------------------------------------------
function idx = sampleCategorical(p, n)
% p must sum to 1
cp = cumsum(p(:));
cp(end) = 1;
r = rand(n,1);
% Vectorized inverse-CDF sampling robust to repeated edges from zero-probability bins
idx = sum(r > cp.', 2) + 1;
idx = max(1, min(numel(p), idx));
end

%% ------------------------------------------------------------------------
function quickPlots(out)
fprintf('N=%d neurons, %d compartments, %d synapses, mean rate = %.2f Hz\n', ...
    out.net.N, out.net.nComp, out.syn.nSyn, out.sim.meanRateHz);

t = out.sim.spikeTimesMs;
n = out.sim.spikeNeurons;
if isempty(t)
    warning('No spikes recorded.');
    return;
end

figure('Name','Microcolumn raster','Color','w');
plot(t, n, '.k', 'MarkerSize', 4);
xlabel('Time (ms)');
ylabel('Neuron index');
title(sprintf('Raster (N=%d, M=%d)', out.net.N, out.syn.M));
grid on;

% Population rates
bin = 10; % ms
edges = 0:bin:out.sim.T;
cnt = histcounts(t, edges);
rate = cnt / out.net.N / (bin/1000);
figure('Name','Population rate','Color','w');
plot(edges(1:end-1), rate, 'LineWidth', 1.2);
xlabel('Time (ms)');
ylabel('Rate (Hz/neuron avg)');
title('Population firing rate');
grid on;

% Population composition
figure('Name','Population sizes','Color','w');
bar(out.net.nPerPop);
xticks(1:out.net.nPop);
xticklabels({out.net.pops.base});
xtickangle(45);
ylabel('# neurons');
title('Cortical population allocation from rate column');
grid on;

end

%% ------------------------------------------------------------------------
function s = mergeStruct(a, b)
s = a;
if isempty(b), return; end
fn = fieldnames(b);
for i = 1:numel(fn)
    if isstruct(b.(fn{i})) && isfield(s, fn{i}) && isstruct(s.(fn{i}))
        s.(fn{i}) = mergeStruct(s.(fn{i}), b.(fn{i}));
    else
        s.(fn{i}) = b.(fn{i});
    end
end
end
