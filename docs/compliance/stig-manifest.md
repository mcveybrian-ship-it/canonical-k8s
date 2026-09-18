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

## ⚠️ Still missing

- **`U_Kubernetes_V2R5_STIG.zip`** — the **Manual** XCCDF. We hold only
  `U_Kubernetes_V2R5_STIG_SCAP_1-3_Benchmark.zip`, which is the *automatable subset*
  (61 rules). **34 V-IDs in the observed range are absent.** Every Kubernetes coverage
  figure and the Container Platform SRG overlap analysis remain FLOORS until it lands.
