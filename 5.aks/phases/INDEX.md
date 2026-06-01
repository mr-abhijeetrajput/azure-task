# APIM 3 — Phase Index

> Each phase is a separate file for clear, focused execution.
> Work through them in order. Mark each ✅ before moving to the next.

| Phase | File | What gets built | Status |
|---|---|---|---|
| 00 | [phase-00-overview-and-network-layout.md](./phase-00-overview-and-network-layout.md) | Architecture diagram, resource names, network layout, deployment order | Reference |
| 01 | [phase-01-shell-variables-and-prechecks.md](./phase-01-shell-variables-and-prechecks.md) | Shell variables + subnet/delegation pre-checks | ⬜ |
| 02 | [phase-02-nsg-verification.md](./phase-02-nsg-verification.md) | NSG rules for `nsg-agw` and `nsg-apim` | ⬜ |
| 03 | [phase-03-vpn-vm-openvpn.md](./phase-03-vpn-vm-openvpn.md) | VPN VM in snet-aks, OpenVPN, .ovpn download | ⬜ |
| 04 | [phase-04-aks-httpbin-ilb-and-entra-rbac.md](./phase-04-aks-httpbin-ilb-and-entra-rbac.md) | httpbin ILB at 10.0.1.50, Entra ID users/groups, K8s RBAC bindings | ⬜ |
| 05 | [phase-05-apim-provisioning-and-tls.md](./phase-05-apim-provisioning-and-tls.md) | APIM External VNet, public IP with DNS label, Let's Encrypt cert, custom domain | ⬜ |
| 06 | [phase-06-application-gateway-waf.md](./phase-06-application-gateway-waf.md) | AGW WAF_v2 private frontend 10.0.3.4, backend ILB 10.0.1.50, health probe | ⬜ |
| 07 | [phase-07-apim-api-policies-and-dns.md](./phase-07-apim-api-policies-and-dns.md) | Orders API, 4 operations, JWT + rate-limit + header-strip policies, Hostinger DNS | ⬜ |
| 08 | [phase-08-postgresql-private-link.md](./phase-08-postgresql-private-link.md) | PostgreSQL Flexible Server, VNet integration, private DNS zone, K8s Secret | ⬜ |
| 09 | [phase-09-workload-identity-and-keyvault.md](./phase-09-workload-identity-and-keyvault.md) | OIDC issuer, Managed Identity, federated credential, Key Vault secret from pod | ⬜ |
| 10 | [phase-10-blob-storage-workload-identity.md](./phase-10-blob-storage-workload-identity.md) | Storage account, container, blob read/write from pod via Workload Identity | ⬜ |
| 11 | [phase-11-end-to-end-test-scenarios.md](./phase-11-end-to-end-test-scenarios.md) | 6 test scenarios: no JWT, bad JWT, happy path, header strip, rate limit, private AGW | ⬜ |

---

## Quick troubleshooting reference

| Symptom | Most likely cause | Fix |
|---|---|---|
| APIM create fails: "IP must have FQDN" | IP has no DNS label | `az network public-ip create` with `--dns-name` (Phase 05) |
| AGW create blocked in portal | NSG missing GatewayManager rule | Add `allow-agw-infra` rule (Phase 02) |
| 502 from APIM | APIM can't reach AGW `10.0.3.4` | Check NSG `allow-apim-to-agw-out` outbound on `nsg-apim` |
| 502 from AGW | VMSS node IP in backend pool | Update pool to `10.0.1.50` only (Phase 06) |
| `curl 10.0.3.4` fails from laptop | Not on VPN or IP forwarding off | Connect VPN; verify NIC IP forwarding ON (Phase 03) |
| nslookup returns public IP for PG | DNS Zone not linked to VNet | Add VNet link to private DNS zone (Phase 08) |
| kubectl Forbidden after Entra login | RoleBinding subject is email not OID | Re-apply `rbac-orders.yaml` with Object IDs (Phase 04) |
| KV 401 from pod | Federated credential namespace/SA mismatch | Verify `--subject system:serviceaccount:orders:orders-sa` (Phase 09) |
| Blob 403 | Wrong role assigned | Assign `Storage Blob Data Contributor` at container scope (Phase 10) |
| OpenVPN connects but can't reach 10.0.x.x | IP forwarding not on NIC | Portal: VM NIC → IP configurations → IP forwarding ON (Phase 03) |
| OpenVPN can't resolve privatelink hostnames | DNS not 168.63.129.16 | Re-run angristan installer with Custom DNS 168.63.129.16 (Phase 03) |
