# Microcolumn MATLAB Model (v4) — Technical Documentation

This document is the **primary, Git-friendly documentation** for the current model implementation in:

- `izh_microcolumn_single_v4.m`

It is written to stay aligned with the latest code updates (single-precision hot path, typed delay-queue events, and STP masking).

---

## 1) Quick start

```matlab
out = izh_microcolumn_single_v4(N, M, xlsxFile, cfg)
```

### Inputs

- `N` — number of cortical neurons in the microcolumn.
- `M` — fixed number of incoming synapses per cortical neuron.
- `xlsxFile` — table file with at least `ME-TYPE`, `rate`, `delay`, plus source columns.
- `cfg` — optional settings struct (merged with defaults).

### Output (`out`)

- `out.cfg` — effective configuration.
- `out.meta` — parsed table/population metadata.
- `out.net` — neuron and compartment-level network data.
- `out.syn` — synapse structures, delays, weights, STP state.
- `out.sim` — simulation results (spikes, final states, rates).

---

## 2) Model pipeline

1. **`readAndCleanTable`**  
   Reads the Excel table, removes invalid rows/columns, normalizes names, checks required columns.

2. **`parseCytoarchitectonicTable`**  
   Splits `ME-TYPE` into base/layer, groups compartments per population, identifies soma compartment.

3. **`instantiateCorticalNeurons`**  
   Allocates `N` neurons by population rates, builds flattened compartment arrays, assigns Izhikevich parameters.

4. **`buildSynapses`**  
   Creates exactly `M` incoming synapses per neuron, sets delays/weights/source identity, and initializes STP fields.

5. **`runSimulation`**  
   Executes time integration with conductance decays, delayed event delivery, external Poisson input, dendritic coupling, spike/reset logic, and STP updates.

---

## 3) STP in v4 (`syn.tauX`, `syn.pX`, `syn.x`, `syn.hasStp`)

### STP fields

- `syn.tauX` — recovery time constant per synapse (`inf` = no STP recovery).
- `syn.pX` — multiplicative usage factor at presynaptic spike.
- `syn.x` — dynamic per-synapse resource state.
- `syn.hasStp` — logical mask defining whether STP is active for each synapse.

### Why `syn.hasStp` exists

`hasStp` is computed as:

```matlab
syn.hasStp = isfinite(tauX);
```

So only synapses with finite `tauX` run STP dynamics.

This provides:

- **Correctness**: STP is applied exactly where configured by pre/post pair rules.
- **Performance**: non-STP synapses are skipped in the STP hot path.

### Where `syn.hasStp` is used

In `runSimulation`, STP logic uses the mask at three points:

1. **Cached subset of STP synapses**
   ```matlab
   idxSTP = find(syn.hasStp);
   ```

2. **Per-step recovery update** (only for `idxSTP`):
   ```matlab
   xstp = syn.x(idxSTP);
   xstp = xstp + ((1 - xstp) .* invTauDt);
   syn.x(idxSTP) = xstp;
   ```

3. **Spike-time STP update** (external and recurrent events):
   ```matlab
   hasStp = syn.hasStp(sids);
   xeff(hasStp) = xeff(hasStp) .* syn.pX(sids(hasStp));
   syn.x(sids(hasStp)) = xeff(hasStp);
   ```

---

## 4) Important implementation updates (latest)

### 4.1 Single-precision simulation hot path

Core dynamic state (`v`, `u`, conductances, STP state) is kept in `single` precision to reduce memory traffic and conversion overhead.

### 4.2 Typed delay-queue events (bug fix)

The delay ring buffer stores event payload as a typed struct:

- `sid` (`uint32`) — synapse indices
- `xeff` (`single`) — event efficacy

This prevents integer/float coercion issues that can trigger errors such as:

> Integers can only be combined with integers of the same class, or scalar doubles.

during operations like:

```matlab
amp = syn.w(sid) .* xeff;
```

---

## 5) Configuration notes

Commonly tuned settings in `cfg` include:

- `T`, `dt`
- `ignoreCC`
- `extRatesHz.*`
- `sensPulses`
- `tauAMPA`, `tauNMDA`, `tauGABAA`, `tauGABAB`
- `excWInitMax`, `inhWFixed`, `tcWeightScale`
- `IinjByPop`
- `recordAllCompSpikes`, `doPlot`

`defaultCfg()` provides baseline values.

---

## 6) Documentation files in this repo

- `documentation.md` (this file): canonical, review-friendly docs.
- `documentation.docx`: Word version for offline sharing.
- `README.md`: short project overview and pointers.

If GitHub shows limited `.docx` diff output (binary behavior), use this Markdown file for complete review history.
