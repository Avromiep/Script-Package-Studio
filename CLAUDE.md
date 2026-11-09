# Script Package Studio: standing rules
- Never let a half-finished tenant switch leave the app pointed at the wrong tenant. No script starts while $script:TenantSwitching is set, and nothing that pumps the UI (Update-UiNow, Set-ItemStatus, Step-Progress, Complete-Progress) runs between `$script:TenantSwitching = $true` and its finally.
- A bulk action's summary must tell the truth. Counts come from real results, never attempts. Never say added, disabled, created or blocked when it wasn't.
- Any loop that pumps the UI locks its window with Lock-ScriptWindow and unlocks in a finally.
- No telemetry. Never log passwords. Don't install, uninstall or switch anything in his real PowerShell module folders or on his work servers. Never use -SkipPublisherCheck, Set-PSRepository or Set-ExecutionPolicy.
- Tests mock Exchange and Graph and never connect to a real tenant. Manual checks use a test account only.
- Never edit or delete a GitHub release or tag. No force-push. Nothing is released until Avromi types "release it".
