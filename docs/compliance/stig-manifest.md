# STIG / SRG reference material — manifest

**The files themselves are gitignored** — public downloads from <https://cyber.mil>,
re-downloadable at any time. What an assessor needs is provenance: what was used, its
exact bytes, and when it was obtained.

Generated 2026-09-18 20:28 UTC. Regenerate by re-running the `sha256sum` loop in git history.

| File | Size | SHA-256 | Obtained |
|---|---|---|---|
| `CCI_List.zip` | 428K | `19a377447af3868d0c985ec7407403fc2eb194d31e4e3178674977f863b397cc` | 2026-09-17 |
| `InstallRoot_5.6x64(1).msi` | 27M | `82719aebcc5372643649f1e4bce0242f0c4a37321703b793e116ad1993f57ae2` | 2026-09-17 |
| `U_Application_Server_V4R5_SRG.zip` | 1.2M | `ea33d7f18f950e86c9e0cc63835cf8802d319804ac143b2020b1fbac13ff2643` | 2026-09-17 |
| `U_ASD_V6R4_STIG.zip` | 1.3M | `3361a742c58ba7cc3f86bc1fa6aa6b0d9a588824c017a90c9b6786df8ffdd681` | 2026-09-18 |
| `U_BIND_9-x_V3R3_STIG.zip` | 2.0M | `393a0aef033b9a988ee146b7a1277b6ef513873c45a5df3cc3278765d8c91b9e` | 2026-09-18 |
| `U_CAN_Ubuntu_22-04_LTS_V2R9_STIG.zip` | 2.0M | `a533fd2758a1832bd4c81e4f2a11497d5331c3148ee8bcf88e81800843a86ffb` | 2026-09-17 |
| `U_CD_Postgres_16_V1R3_STIG.zip` | 4.3M | `2970f7d32e18dce3f0d83739a85943927cf64c5373f58cb100d8889b0ba29a28` | 2026-09-17 |
| `U_Container_Platform_V2R4_SRG.zip` | 2.8M | `975a9e421e62e0ea52b1824e4a719aee87eed9070d5a3145fa9817f6498d99fe` | 2026-09-17 |
| `U_Database_V4R5_SRG.zip` | 1.2M | `c604242fe07c4f4d04d5723d559cfa621b3313ce3bf44809b71f2bc0f94f20b9` | 2026-09-17 |
| `U_GPOS_V3R3_SRG.zip` | 1.2M | `97026655bce18d91e12c9c0a9fd54288989f0b483d3b92ec615e2dc0544e6f24` | 2026-09-17 |
| `U_Kubernetes_V2R5_STIG_SCAP_1-3_Benchmark.zip` | 32K | `049b63b6808c7433fbf2d1e6d9d6ed5ce8413d35dcd97963a27d07158f270584` | 2026-09-17 |
| `U_Web_Server_V4R5_SRG.zip` | 1.2M | `e7936ed668282a5536b1be9713fc6d69d2be3338c7728e8c2e701c5e5f64d4bd` | 2026-09-17 |
| `U_Kubernetes_V2R6_STIG.zip` | 2.9M | `2e66cc46e19889f337b40a7827745146c40c7b532529c03d826ba7462419876a` | 2026-09-18 |
| `CAL_by_Port-20260901.pdf` | 22M | `d80605b51e67e77c7218ab56c16fb3ff594dfa2d1eb5052cb80abf034e78b857` | 2026-09-18 |
| `CAL_by_Service-20260901.pdf` | 21M | `6cf01c5e322d803825ebfd039a0526ab103fefea4343540c5fcce7cf9562c5f4` | 2026-09-18 |
| `CAL_Excel_format_20260901.xlsx` | 3.3M | `6b5795a5243f45eef32ef244482ea206f33cf31b5ad50563d17f3c49936cac44` | 2026-09-18 |
| `CAL_Record_of_Changes_20260901.xlsx` | 564K | `ea9348e3d4685ff18fff4498f3deefc74fc05aadd1a5163a27e90fb71cd9325a` | 2026-09-18 |
| `DoDIN APL Report_18-Sep-2026.pdf` | 256K | `2f371495d2c9e144147c32d57052961ef0fa9090653b73b0de7329ffc36f0dd2` | 2026-09-18 |
| `DoDIN APL Report_18-Sep-2026.xls` | 88K | `eb7679917046d638309dffe3991d1fecd3fa268ca3902b411bfaa5038186e72d` | 2026-09-18 |
| `unclass-certificates_pkcs7_DoD.zip` | 120K | `32595adbe752df5823cedd2c6a4f206c07fcc3c1520fb831015204e9fbb75711` | 2026-09-18 |

## ✅ Nothing on the list is missing (2026-09-30)

- **`U_Kubernetes_V2R6_STIG.zip`** — the **Manual** XCCDF, obtained 2026-09-18. It supersedes the
  V2R5 manual this section used to ask for (92 rules vs the SCAP benchmark's 61, which is still V2R5).
- Rows added 2026-09-30 for the files that arrived after this manifest was first generated. The CAL
  and the DoDIN APL report are CAC-only downloads, not public; they are listed for provenance only.
- **Deliberately not listed:** two local documents in the folder that are not DISA downloads. This
  file is tracked and `origin` is public.
