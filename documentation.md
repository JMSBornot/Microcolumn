>> cfg = struct; cfg.T = 1000; tic; out = izh_microcolumn_single_v2(800, 120, 'neuron_data.xlsx', cfg); toc
Below is a field-by-field description of the out struct returned by izh_microcolumn_single(), written so you can lift it directly into function documentation. I will use your concrete run (N=800, M=120) to interpret the example numbers.
________________________________________
Top-level out
out is a self-contained bundle with five blocks:
	out.cfg : the fully-resolved configuration used for the run (defaults merged with user overrides).
	out.meta : metadata parsed directly from the Excel table (row-level + population-level definitions, and source-column mapping).
	out.net : the instantiated microcolumn network: neuron allocation, compartment layout, per-compartment Izhikevich parameters.
	out.syn : the synapse list (exactly M incoming synapses per neuron), including delays, weights, external sources, STP parameters, and adjacency.
	out.sim : simulation outputs (final states + spike raster + summary rates).
________________________________________
out.cfg (configuration actually used)
out.cfg is the final config struct after merging defaults (defaultCfg()) with any user overrides.
Key fields (units in parentheses):
Time / integration
	cfg.T (ms): total simulated time.
	cfg.dt (ms): integration time step.
	Derived: out.sim.nSteps = round(cfg.T / cfg.dt).
Connectivity interpretation switches
	cfg.ignoreCC (logical): if true, the CC source column is zeroed before normalization, so CC never contributes probability mass.
	cfg.reweightSrcPctByNS (logical): if true, performs the global NS reweighting:
matW(q,j)=NS(q)⋅srcPct(q,j)
srcPctAdj=100⋅matW/∑matW(:)

so sum(srcPctAdj(:))=100 and row sums encode compartment share of synapses.
	cfg.useNSForCompartmentAllocation (logical): if reweightSrcPctByNS is off, this controls whether NS is used only to split M across compartments (legacy mode).
External afferents (Poisson)
	cfg.extRatesHz.<name> (Hz): per-synapse Poisson rate for external sources such as TCs, TCn, BSTEM, SENS, etc.
	cfg.sensPulses: optional pulse schedule [tStart, tEnd, sensRateHz, tcsRateHz] that temporarily overrides SENS and TCs rates.
Synaptic kinetics and biophysics
	cfg.tauAMPA, cfg.tauNMDA, cfg.tauGABAA, cfg.tauGABAB (ms): conductance decay time constants.
	cfg.fracAMPA, cfg.fracNMDA, cfg.fracGABAA, cfg.fracGABAB: split of a synaptic “event” into receptor components.
	cfg.Eexc, cfg.EgabaA, cfg.EgabaB (mV): reversal potentials.
Weight initialization
	cfg.excWInitMax: excitatory weights initialized uniformly in [0, excWInitMax].
	cfg.inhWFixed: inhibitory weights set to this constant.
	cfg.tcWeightScale: multiplier applied to excitatory external categories (TCs, TCn, SENS, BSTEM).
Optional tonic current injection
	cfg.IinjByPop: struct mapping base-name -> current (applied to soma compartments only).
________________________________________
out.meta (table parsing and source mapping)
out.meta contains only information derived from the Excel table, plus a mapping that links source columns to cortical populations.
out.meta.rows (42×1 struct)
One struct per table row, i.e., per population compartment definition.
Each element has:
	rows(i).name : the original ME-TYPE string (e.g., 'p4-L4').
	rows(i).base : base population name (e.g., 'p4').
	rows(i).layer: layer suffix string (e.g., 'L4', 'L3', 'L2', 'L1').
	rows(i).rate : soma “rate” (% of cells) only meaningful for the soma row; compartments typically have 0.
	rows(i).delay (ms): compartment delay-to-soma used for synaptic delay assignment (converted to steps later).
	rows(i).NS : number of synapses for the compartment (used as a capacity/weight, not as absolute synapse count since in-degree is fixed to M).
	rows(i).srcPct (1×nSources): raw weights from each presynaptic source column for that compartment.
out.meta.pops (1×20 struct)
One struct per cortical population (base name), each grouping multiple compartment rows.
Fields (most relevant):
	pops(p).base : population base name (e.g., 'p4', 'b2', 'ss4(L4)').
	pops(p).rowIdx : indices into meta.rows that belong to this pop.
	pops(p).compNames : names for each compartment row (ordered).
	pops(p).layers : layer labels for each compartment.
	pops(p).delaysMs : per-compartment delays (ms), sorted ascending.
	pops(p).rates : per-compartment rates (soma row has >0; others are 0).
	pops(p).NS : per-compartment NS.
	pops(p).srcPct : matrix (nComp × nSources) of raw synapse weights per compartment.
	pops(p).somaCompLocal : which local compartment index is the soma for this population.
	pops(p).somaRatePct : the soma row’s rate value (used for allocating neurons).
	pops(p).morphClass : coarse morphology class used to pick Izh parameters (nb1, p23, b, nb, ss4, p4, p56).
	pops(p).isExcitPop : whether the population is treated as excitatory.
out.meta.srcCols (1×22 cell)
The source column names from the table, in the original Excel order, excluding ME-TYPE, rate, delay, and NS.
This order defines the categorical encoding used by synapses (syn.srcCode).
out.meta.src2pop (1×22 double)
Mapping from source column index → cortical population index:
	src2pop(j) = k means srcCols{j} matches meta.pops(k).base → it is an internal cortical source.
	src2pop(j) = 0 means the source column is external (e.g., thalamic/sensory/brainstem categories, or any source name not instantiated as a cortical population).
In your printout:
src2pop: [1 2 3 ... 20 0 0]
meaning 20 source columns correspond to the 20 cortical populations, and the final 2 correspond to external-only sources.
________________________________________
out.net (instantiated neurons + flattened compartments)
out.net is the actual network realization built from meta and your chosen N.
Population-level
	net.N : number of cortical neurons (here 800).
	net.nPop : number of cortical populations (here 20).
	net.pops : the population definitions (copied from meta.pops, and later augmented with synapse-related fields such as srcPctAdj and compAllocW).
Neurons allocated per population
	net.nPerPop (20×1): integer neuron counts per population after “largest remainder” rounding.
	Invariant: sum(net.nPerPop) == net.N.
	net.popNeuronIds (20×1 cell): for each population, the list of neuron indices belonging to it.
Per-neuron indexing into compartments
Neurons are multi-compartment; compartments are stored as a single flattened array 1..net.nComp.
	net.neuronPop (N×1): population index of each neuron.
	net.neuronMorph (N×1 string): morphology class string used by STP rules.
	net.neuronCompStart (N×1): starting global compartment index of neuron n.
	net.neuronCompCount (N×1): number of compartments of neuron n.
	net.neuronSomaComp (N×1): global compartment index of the soma for neuron n.
	net.neuronGup, net.neuronGdown (N×1): dendritic coupling conductances used in simulation.
Flattened compartments (global arrays)
	net.nComp: total number of compartments (here 2035).
	Computed as: ∑_p▒〖nPerPop(p)⋅nCompPerNeuron(p)〗.
	net.compNeuron (nComp×1): owning neuron index for each compartment.
	net.compPop (nComp×1): owning population index for each compartment.
	net.compLocal (nComp×1): local compartment number within its neuron (1..neuronCompCount).
	net.compDelayMs (nComp×1, ms): per-compartment delay value copied from table.
	net.compIsSoma (nComp×1 logical): true for soma compartments.
Per-compartment Izhikevich parameters
These arrays are length nComp, one value per compartment:
	net.C, net.k, net.vr, net.vt (standard Izh parameters)
	net.a, net.b (recovery dynamics)
	net.cReset, net.dReset (reset values after spike)
	net.vpeak (spike threshold/peak; soma and dendrite can differ)
These are assigned from the morphology library (izhParamLibrary()), with soma vs dendrite using different vpeak and cReset.
________________________________________
out.syn (synapse list, fixed in-degree M)
out.syn stores all synapses explicitly as a table of length nSyn = N*M.
In your run:
	syn.M = 120
	syn.nSyn = 96000 = 800*120
Core connectivity arrays (length nSyn)
Each synapse has index s = 1..syn.nSyn:
	syn.preNeuron (uint32):
	1..N for internal cortical presynaptic neurons,
	0 for external Poisson sources.
	syn.postComp (uint32): postsynaptic compartment index (1..net.nComp).
	syn.delaySteps (uint16): synaptic delay in simulation steps:
delaySteps(s)=max⁡(1,"round"(compDelayMs(postComp(s))/dt))

	syn.isExternal (logical): true iff preNeuron == 0.
	syn.srcCode (uint8): categorical code j pointing into syn.srcNames{j}.
	syn.srcNames (1×nSources cell): same list as meta.srcCols, defining the meaning of each srcCode.
	syn.isExcit (logical): true for excitatory sources (p*, ss*, and external excit categories like TCs, TCn, SENS, BSTEM), false otherwise.
	syn.w (single): synaptic “event amplitude” (conductance scale).
	excitatory: random in [0, cfg.excWInitMax], optionally scaled for TC/SENS/BSTEM
	inhibitory: fixed cfg.inhWFixed
External sources
	syn.nExt: number of synapses whose source is external (here 3065).
	syn.externalIdx (nExt×1 uint32): indices s such that syn.isExternal(s) == true.
	syn.extRateHz (nSyn×1 single): per-synapse Poisson rate (Hz) used only when isExternal(s)=true.
	The rate is selected by syn.srcNames{syn.srcCode(s)} from cfg.extRatesHz, with optional pulse overrides during simulation.
Short-term plasticity (STP) per synapse
This implementation uses a simple “resource” variable x(s) that:
	recovers toward 1 with time constant tauX(s),
	is multiplied by pX(s) at presynaptic spikes,
	and scales the synaptic effect at that event.
Fields:
	syn.tauX (nSyn×1 double, ms): recovery time constant; Inf means “no STP”.
	syn.pX (nSyn×1 single): event multiplier applied when a spike occurs.
	syn.x (nSyn×1 single): dynamic resource variable (initialized to 1).
Event handling in the simulator:
	When a presynaptic spike arrives, the delivered amplitude is:
amp=w(s)⋅xeff(s)

	x then recovers each step (for finite tauX):
x←x+dt⋅(1-x)/tauX

Adjacency / routing helpers
	syn.outgoing (N×1 cell): for each presynaptic neuron n, the list of synapse indices that originate from it (internal synapses only).
	syn.maxDelaySteps: maximum delaySteps across all synapses (here 12). Used to size the ring buffer that schedules delayed synaptic events.
________________________________________
out.sim (simulation results)
out.sim contains the outputs of runSimulation().
Timing
	sim.dt (ms): copy of cfg.dt.
	sim.T (ms): copy of cfg.T.
	sim.nSteps: number of integration steps (here 2000 for T=1000 ms, dt=0.5 ms).
Final state per compartment
	sim.finalV (nComp×1, mV): final membrane potential for each compartment.
	sim.finalU (nComp×1): final recovery variable for each compartment.
Spike outputs (soma spikes only by default)
	sim.spikeTimesMs (nSpikes×1, ms): spike times.
	sim.spikeNeurons (nSpikes×1): neuron indices (1..N).
	sim.nSpikes: total number of recorded soma spikes (here 228).
	sim.meanRateHz: mean firing rate over the population:
meanRateHz=nSpikes/N⋅1000/T

Your output 0.2850 Hz matches 228 / 800 / 1s.
If cfg.recordAllCompSpikes = true, two extra fields are also included:
	sim.compSpikeTimesMs
	sim.compSpikeComps
Important implementation detail: only soma spikes propagate synaptic output (syn.outgoing). Dendritic compartments can “spike” (cross vpeak) and reset, but they do not trigger outgoing synapses in this version.
________________________________________
Useful “how to interpret” recipes (for documentation)
Find a neuron’s population name
n = 10;
p = out.net.neuronPop(n);
popName = out.net.pops(p).base;
Get all compartments of a neuron
n = 10;
c0 = out.net.neuronCompStart(n);
k  = out.net.neuronCompCount(n);
comps = c0 + (0:k-1);
Interpret a synapse row s
s = 1234;
srcName = out.syn.srcNames{out.syn.srcCode(s)};
postComp = out.syn.postComp(s);
postNeuron = out.net.compNeuron(postComp);
postPop = out.net.pops(out.net.compPop(postComp)).base;
Verify invariants (good for debugging)
	out.syn.nSyn == out.net.N * out.syn.M
	each neuron receives exactly M synapses:
counts = accumarray(double(out.net.compNeuron(double(out.syn.postComp))), 1, [out.net.N, 1]);
all(counts == out.syn.M)
________________________________________
If you later want me to cross-reference this documentation against older files you uploaded in previous sessions, please re-upload them (some previously uploaded files can expire)

