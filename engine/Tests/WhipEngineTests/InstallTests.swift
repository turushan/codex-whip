// Ported from tests/test_install.py: installation checks with a mocked login service.
//
// Every Python test here drives start_service with subprocess.run, Path.home, agent_path,
// service_running and time.time patched. Service.startService has none of those seams: it calls
// /bin/launchctl directly (Service.launchctl via serviceRunning and `bootstrap`), writes the command
// link under Paths.home (FileManager.homeDirectoryForCurrentUser), writes Paths.agentPath, and
// stamps enabled_at from the wall clock. Running it would install a real login job in the user's
// real home, so each test is skipped until those seams exist.
//
// NEEDS SEAM: Service.startService / Service.checkCommandTarget / Service.launchctl. Inject a home
// directory (for commandLink and agentPath), a launchd client (for serviceRunning, bootstrap and
// bootout), and a clock (for enabled_at = 20000).

import Testing
@testable import WhipEngine

@Suite struct InstallTests {
    // test_fresh_start_installs_command_and_login_job
    // NEEDS SEAM: home, launchd client and clock for Service.startService.
    @Test(.disabled("NEEDS SEAM: Service.startService runs the real launchctl and uses the real home"))
    func freshStartInstallsCommandAndLoginJob() {}

    // test_preserved_start_keeps_timers_journal_scope_and_history
    // NEEDS SEAM: home and launchd client for Service.startService.
    @Test(.disabled("NEEDS SEAM: Service.startService runs the real launchctl and uses the real home"))
    func preservedStartKeepsTimersJournalScopeAndHistory() {}

    // test_fresh_restart_resets_retry_scope_but_retains_history
    // NEEDS SEAM: home, launchd client and clock for Service.startService.
    @Test(.disabled("NEEDS SEAM: Service.startService runs the real launchctl and uses the real home"))
    func freshRestartResetsRetryScopeButRetainsHistory() {}

    // test_preserve_flag_without_previous_state_installs_fresh
    // NEEDS SEAM: home, launchd client and clock for Service.startService.
    @Test(.disabled("NEEDS SEAM: Service.startService runs the real launchctl and uses the real home"))
    func preserveFlagWithoutPreviousStateInstallsFresh() {}

    // test_existing_matching_command_is_kept_on_reinstall
    // NEEDS SEAM: home for Service.commandLink and a launchd client for Service.startService.
    @Test(.disabled("NEEDS SEAM: Service.startService runs the real launchctl and uses the real home"))
    func existingMatchingCommandIsKeptOnReinstall() {}

    // test_different_existing_command_is_never_replaced_or_started
    // NEEDS SEAM: home for Service.commandLink (checkCommandTarget reads the real
    // ~/.local/bin/codex-whip), and startService asks the real launchctl before checking it.
    @Test(.disabled("NEEDS SEAM: Service.checkCommandTarget uses the real home; startService runs launchctl first"))
    func differentExistingCommandIsNeverReplacedOrStarted() {}
}
