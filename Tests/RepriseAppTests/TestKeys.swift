import RepriseCore
@testable import Reprise

/// One library key for the whole test run, so reopened stores and readers share it; tests never
/// touch the login keychain.
let testKeys = VaultKeys.ephemeral()

/// Waits for the text of every screen. A test process's first text request can take half a minute
/// while the Neural Engine compiler prepares Vision's model, longer than capture waits.
func patientProcessor() -> CaptureImageProcessor { CaptureImageProcessor(textWait: 300) }
