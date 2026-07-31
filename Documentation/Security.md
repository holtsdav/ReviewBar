# Security model

## Assets and trust boundaries

The App Store Connect `.p8` private key is the highest-value asset. If stolen, it can be used outside ReviewBar with the roles and app access Apple assigned to that key. ReviewBar reduces exposure but cannot make a compromised or jailbroken device trustworthy.

Trust boundaries:

1. Files picker → ReviewBar memory during import.
2. ReviewBar → iOS Keychain for credential persistence.
3. ReviewBar → `api.appstoreconnect.apple.com` through system TLS.
4. Decoded Apple models → protected local dashboard cache.

There is no ReviewBar backend, account, analytics SDK, crash SDK, widget extension, Keychain access group, or app-group container.

## Controls

- Imports accept one regular file of at most 16 KiB, validate one PKCS#8 PEM block, and parse it with CryptoKit P-256 before use.
- The original security-scoped file URL is accessed only for the import operation and is not bookmarked or copied.
- Credentials use one precise generic-password Keychain query with service/account identifiers, synchronization disabled, and `WhenUnlockedThisDeviceOnly` accessibility.
- ES256 JWTs use raw 64-byte JOSE signatures, live only in the signer actor’s memory, last ten minutes, and rotate with 60 seconds remaining.
- Every production request is constructed as GET, with a token scoped to the exact path and query. Authorization is never placed in a URL.
- Authenticated URLs and redirects must remain on exact Apple HTTPS host boundaries.
- The ephemeral URL session has cookies and URL caching disabled.
- Cached decoded data uses an atomic protected file; the `.p8`, JWT, IDs required to authenticate, headers, and raw responses are never cached there.
- No code prints or logs credentials, tokens, requests, raw responses, or customer review text.
- Disconnect verifies deletion of the exact Keychain item before reporting success, cancels in-flight data work, and erases all ReviewBar local account state. If local cleanup fails after credential deletion, the app records a nonsecret retry marker and retries cleanup on the next launch.

## Residual risks

- Swift and CryptoKit do not guarantee deterministic zeroization of temporary secret buffers. The import UI minimizes copies and clears its retained PEM after a successful connection.
- A malicious trusted root, compromised OS, hostile keyboard, or injected runtime can defeat on-device protections.
- Cached review and app data is private developer information even though it is not an authentication secret. It is protected on disk but available after the user has unlocked the device once.
- The original `.p8` remains under the user’s control in Files.
- A team key is account-wide. An individual key on a dedicated, app-limited Developer user is the recommended minimum exposure.

## Incident response

If a key may be exposed, revoke it in App Store Connect immediately, remove the ReviewBar connection, create a replacement key, and review that App Store Connect user’s role/app access. Apple does not permit a revoked key to be restored.
