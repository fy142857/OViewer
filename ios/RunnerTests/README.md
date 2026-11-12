# Upload native XCTest

`UploadValidation` is a shared, simulator-only Xcode scheme. It builds a separate
`UploadValidationHost.app` and the `UploadValidationTests.xctest` bundle. Both
targets keep the **iOS 12.0** deployment target.

The host compiles the same six upload Swift source files as `Runner`, together
with a small UIKit app delegate. It does **not** compile or launch Runner's app
delegate, register Flutter plugins, start a Flutter engine, or restore the
application's real upload queue. Its bundle ID is
`com.oviewer.oviewer.uploadvalidation`; a runtime guard refuses a different ID.
The tests use temporary storage roots and unique Keychain service names. The
sanitized `test/fixtures/uploads/uploaded.html` is copied into the XCTest bundle.
The simulator host is signed locally with the ad hoc identity (`-`) and only its
own test Keychain access group. It uses no developer certificate, Team, or
provisioning profile, and does not change Runner's signing configuration.

## Run on macOS

Requirements: Xcode with an available iOS Simulator runtime, Python 3.9 or newer,
and the project's Flutter **3.16.0** SDK. CocoaPods is not needed by this isolated
scheme: the build phase selects and embeds Flutter's existing simulator engine
framework directly. It does not build a Dart application or change `pubspec.lock`.

From the repository root:

```sh
xcrun simctl list devices available
python3 scripts/run_upload_ios_tests.py \
  --flutter-root /absolute/path/to/flutter-3.16.0 \
  --simulator-id SIMULATOR_UDID
```

Replace the SDK path and `SIMULATOR_UDID` with actual values. The helper verifies
the SDK version and simulator, downloads missing iOS SDK artifacts through
`flutter precache --ios`, and runs serial XCTest with the isolated scheme. It does
not erase simulators, install on physical devices, start CI, or run `Runner`.

Each invocation uses a new `build/ios-upload-validation/<timestamp>/` directory
containing `xcodebuild.log`, `UploadValidation.xcresult`, and `summary.json`. A
successful exit requires both a successful `xcodebuild test` and an observed pass
for every declared upload XCTest method. Started or skipped cases do not count
as passed.

For direct Xcode use, select the shared **UploadValidation** scheme and an iOS
Simulator destination. Set `FLUTTER_ROOT` to the Flutter 3.16.0 SDK in build
settings, or generate `Flutter/Generated.xcconfig` using that SDK first.

## Checks available without Xcode

```sh
python3 scripts/verify_upload_ios_project.py
python3 -m unittest scripts.tests.test_upload_ios_validation scripts.tests.test_ios_minimum -v
```

These checks parse PBX objects and file references, validate scheme targets,
test-host isolation, framework linkage, fixture resources and deployment
settings, and exercise the preparation scripts with temporary fixtures. They do
**not** compile Swift, link Flutter, launch a simulator, or execute XCTest.

The existing Ruby deployment guard can also be checked on a machine with Ruby,
`xcodeproj`, and `cocoapods` installed:

```sh
ruby scripts/tests/ios_deployment_target_guard_test.rb
```

## Verification limits

The XCTest methods cover bounded original-file copying, cancellation,
storage errors, request/credential policy, body integrity, journal isolation,
logout crash fencing, explicit same-size static-image conversion (including orientation
and rejection of multiple frames), receipt credential removal and migration, and
verification of real sanitized upload HTML. The runner derives the required test
count from the source files, so newly added cases cannot be silently skipped. They use
no E-Hentai account and perform no remote upload or publication.

Simulator unit tests do not establish reliable transfer while a real phone is
locked, iOS background wake-up behavior, proxy behavior, force-quit recovery, or
runtime compatibility on an actual iOS 12 device. Those remain separate device
acceptance requirements. Adding the target and passing project-structure checks
must never be reported as an executed Xcode or XCTest pass.

## Background redirect acceptance remains open

The iOS runtime submits a file-backed POST through `URLSessionConfiguration.background`.
Apple documents that background sessions follow redirects automatically and do
not call the redirect delegate that can approve or reject redirects for ordinary
sessions. Adding that delegate would not restrict this transport.
[Apple background-session limitations](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)

The current runtime checks the final upload URL, account, gallery and returned
file IDs before confirming a batch. These are checks after the request. They
cannot prove that an intermediate redirect did not replay the POST or send its
multipart body elsewhere. Domain-scoped cookies limit cookie destinations but do
not provide the same boundary for tokens inside the multipart file. Accumulated
`countOfBytesSent`, even when bounded to the prepared body length, is not a count
of POST requests.

HTTP permits POST-to-GET conversion for 301/302; 303 directs a read, whereas
307/308 preserve the method. The Android endpoint's observed 302 response and
the app's independent one-GET verification of the original gallery do not
establish iOS behavior.
[RFC 9110 redirect semantics](https://www.rfc-editor.org/rfc/rfc9110.html#name-redirection-3xx)

This remains an explicit iOS acceptance limit, not a passing XCTest result.
Use the isolated validation host with a controlled HTTPS endpoint and synthetic
request data to observe real background-session behavior. Record server-side
POST counts and body hashes, and verify that 302/303 reads send no body. Cover
301/307/308, another host/gallery, action URLs, a two-hop redirect that returns
to the initial gallery, and an interrupted GET followed by process restart.
Exercise foreground, lock-screen/system termination and force-quit separately.
`URLProtocol` mocks do not reproduce the system-owned background transport.
Production upload endpoint restrictions and TLS validation must remain intact;
these fixture experiments do not establish live-site or iOS 12 device acceptance.

If every redirect must be blocked before it can resend the upload body, the
smallest architectural alternative is a default/ephemeral session with an
explicit redirect policy. That loses system-owned continuation after the app's
limited background execution ends. Retaining the existing background architecture
requires accepting its platform redirect limitation and collecting the above
evidence; a strict guarantee with persistent background transfer would require a
different server-side upload protocol. No such architecture change is included here.
