#pragma once

// Starts the Apple coordinator. No hook is installed without an Ed25519
// approval matching all three client files and this dylib, a compiled trust
// key, a reviewed executable RVA and unmodified entry bytes. An empty trust
// root intentionally disables activation. ABI/game parity remains separate
// from the isolated detour smoke test.
void BSTMacStartHooks();
