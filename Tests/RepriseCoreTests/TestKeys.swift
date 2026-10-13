import RepriseCore

/// One library key for the whole test run, so reopened stores and readers share it; tests never
/// touch the login keychain.
let testKeys = VaultKeys.ephemeral()
