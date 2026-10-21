import sys, numpy as np, soundfile as sf, coremltools as ct
pkg, wav, out = sys.argv[1:4]
m = ct.models.MLModel(pkg, compute_units=ct.ComputeUnit.CPU_ONLY)
spec = m.get_spec()
ins = {i.name: list(i.type.multiArrayType.shape) for i in spec.description.input}
n = np.arange(960).reshape(960,1); k = np.arange(481).reshape(1,481)
a = ((n*k)%960).astype(np.float64)*(2*np.pi/960); c=np.cos(a).astype(np.float32); s=np.sin(a).astype(np.float32)
st = {k_: np.zeros(v, np.float32) for k_, v in ins.items() if k_ not in ("input_frame","gx_dft_cos","gx_dft_sin")}
st["erb_norm_state"] = np.linspace(-60,-90,32,dtype=np.float32)
st["band_unit_norm_state"] = np.linspace(0.001,0.0001,96,dtype=np.float32).reshape(1,96,1)
x,_ = sf.read(wav, dtype="float32"); x = x[:len(x)-len(x)%480]; res=[]
for i in range(0,len(x),480):
    fr = x[i:i+480]
    r = m.predict({"input_frame": fr, **st, "gx_dft_cos": c, "gx_dft_sin": s})
    res.append(r["enhanced_audio_frame"].astype(np.float32))
    for k_ in st:
        if k_ == "analysis_mem": st[k_] = fr.copy()
        else: st[k_] = r["new_"+k_].astype(np.float32).reshape(st[k_].shape)
np.concatenate(res).astype(np.float32).tofile(out)
