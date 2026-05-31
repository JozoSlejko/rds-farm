# When to use Azure Virtual Desktop (AVD) instead

[← Back to main README](../README.md)

If you don't have a hard requirement for self-managed RDS, **Azure Virtual Desktop** is the modern direction:

- No Broker / Gateway / Web Access VMs to operate.
- No public IPs at all (reverse-connect over outbound 443).
- Per-user CALs included in Microsoft 365 E3/E5 / Windows 11 multi-session entitlements.
- Use [`Azure/avdaccelerator`](https://github.com/Azure/avdaccelerator) for an enterprise-scale Bicep landing zone.

Stick with classic RDS (this template) when you need:

- Windows Server multi-session for apps that don't support Windows 11 multi-session.
- On-prem licensing parity (existing RDS CALs).
- Air-gapped or sovereign environments where AVD isn't available.

## License

MIT. The DSC role-deployment script is derived from the structure used by the historical `Azure/RDS-Templates` repository, modernized for current PowerShell `RemoteDesktop` cmdlets.
