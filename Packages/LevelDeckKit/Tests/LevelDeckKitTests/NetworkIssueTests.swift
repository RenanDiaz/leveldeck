@preconcurrency import Network
import Testing
@testable import LevelDeckKit

@Suite("NetworkIssue")
struct NetworkIssueTests {
    @Test func posixCodes() {
        let cases: [(POSIXErrorCode, NetworkIssue.Kind)] = [
            (.ECONNABORTED, .connectionLost),
            (.ECONNRESET, .connectionLost),
            (.ETIMEDOUT, .connectionLost),
            (.ECONNREFUSED, .refused),
            (.EHOSTUNREACH, .unreachable),
            (.ENETDOWN, .unreachable),
            (.EACCES, .other),
        ]
        for (code, kind) in cases {
            #expect(NetworkIssue(NWError.posix(code)).kind == kind, "\(code)")
        }
    }

    @Test func dnsPolicyDeniedIsLocalNetworkDenied() {
        #expect(NetworkIssue(NWError.dns(-65570)).kind == .localNetworkDenied)
        #expect(NetworkIssue(NWError.dns(-65537)).kind == .unreachable)
    }

    @Test func tlsErrorsAreHandshakeFailures() {
        // errSSLPeerHandshakeFail: the server aborted the handshake (unknown key or identity).
        #expect(NetworkIssue(NWError.tls(-9824)).kind == .handshakeFailed)
    }

    @Test func keepsTechnicalDetail() {
        #expect(!NetworkIssue(NWError.posix(.ECONNABORTED)).detail.isEmpty)
    }
}
