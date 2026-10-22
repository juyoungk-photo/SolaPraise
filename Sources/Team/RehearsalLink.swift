//
//  RehearsalLink.swift
//  SolaPraise
//
//  The team's devices in one room, talking directly — Wi-Fi or Bluetooth,
//  no internet — while a chart is open: a chord fixed on one stand is on
//  every other stand in the room at once.
//
//  WHY: the team sheet and Drive keep corrections for good, but each trip
//  through them is seconds — upload, write a cell, the others' next read,
//  a download. In rehearsal the leader fixes the bridge and the band is
//  reading it the same moment. Only the change goes (ChartDelta), straight
//  to the devices nearby; the sheet still gets the whole correction a
//  moment later, for anyone not in the room and for next week.
//
//  ONE READING FOR THE ROOM: each device reads a chart's chords on its
//  own, and two readings of one page can differ — a chord one finds the
//  other does not — so a change could fall on nothing. A device opening a
//  chart with someone nearby asks for theirs first (`want`), takes their
//  chords whole (`chords`), and reads for itself only when nobody answers.
//  A change that still does not fit asks again.
//
//  Only the team's devices: each says which team it is by a digest of the
//  team sheet's id (never the id itself), and only those connect. The
//  session is encrypted. Running only while a chart is open.
//

import Foundation
import MultipeerConnectivity
import CryptoKit

@MainActor
final class RehearsalLink: NSObject, ObservableObject {

    static let shared = RehearsalLink()

    /// Who is connected, by the name they show.
    @Published private(set) var peers: [String] = []

    struct Message: Codable {
        enum Kind: String, Codable {
            /// What changed (ChartDelta).
            case delta
            /// A chart's lyric fixes, all of them.
            case lyrics
            /// 「Who has this chart's chords?」 — sent when a chart is opened
            /// with someone nearby, or when a change did not fit this copy.
            case want
            /// A chart's chords, all of them: the answer to `want`, so the
            /// room works from one reading rather than one per device.
            case chords
            /// 「This is the reading I have」, as a digest: sent when a chart
            /// is open and the room changes, so two stands that read the
            /// chart each on their own before they met find out, and one
            /// takes the other's.
            case digest
        }
        var kind: Kind
        /// The chart: the attachment's file id and which of its pages.
        var fileId: String
        var key: String
        /// The content, as XFDF — the standard form of a PDF's annotations:
        /// an <add>/<modify>/<delete> command for a change, a whole
        /// document for a chart's chords or its lyric fixes.
        var xfdf: String? = nil
        var digest: String? = nil
        /// The device it is from, and — for an answer or a request meant for
        /// one device — the device it is for.
        var sender: String = ""
        var to: String? = nil
        /// Who fixed it, for the line that says so.
        var from: String
    }

    /// 「sp-rehearsal」: Bonjour's service type, as in Info.plist.
    private static let service = "sp-rehearsal"

    private var me: MCPeerID?
    private var instance = UUID().uuidString
    /// One session holds eight devices at most — itself among them — so a
    /// team of ten was more than one could carry: the ninth stand never
    /// joined. Each device keeps as many as it needs, every other device
    /// in one of them, all connected directly.
    private var sessions: [MCSession] = []
    private var session: MCSession? { sessions.first }
    /// Short of the limit of eight, for invitations still being answered.
    private static let perSession = 6
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var team = ""
    private var users = 0
    private var handlers: [UUID: (Message) -> Void] = [:]

    /// The team, as a digest of the sheet id: enough to tell teams apart,
    /// nothing to read the sheet by.
    static func teamTag(_ sheetId: String?) -> String {
        let digest = SHA256.hash(data: Data((sheetId ?? "solapraise").utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// While a chart is open. Counted: two stands open, one link.
    func start(team: String, name: String) {
        users += 1
        guard session == nil else { return }
        self.team = team
        let peer = MCPeerID(displayName: String(name.prefix(30)).isEmpty ? "팀원" : String(name.prefix(30)))
        me = peer
        instance = UUID().uuidString
        sessions = [newSession(for: peer)]
        let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["team": team, "id": instance],
                                                   serviceType: Self.service)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.service)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func stop() {
        users = max(users - 1, 0)
        guard users == 0 else { return }
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        for session in sessions { session.disconnect() }
        advertiser = nil
        browser = nil
        sessions = []
        peers = []
    }

    /// To every device connected, at once and in order.
    /// This device, as the room knows it.
    var me_: String { instance }

    func send(_ message: Message) {
        var message = message
        message.sender = instance
        guard let data = try? JSONEncoder().encode(message) else { return }
        for session in sessions where !session.connectedPeers.isEmpty {
            try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
        }
    }

    private func newSession(for peer: MCPeerID) -> MCSession {
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }

    /// A session with room for one more, made when all are full.
    fileprivate func roomySession() -> MCSession? {
        guard let me, !sessions.isEmpty else { return nil }
        if let roomy = sessions.first(where: { $0.connectedPeers.count < Self.perSession }) { return roomy }
        let added = newSession(for: me)
        sessions.append(added)
        return added
    }

    fileprivate func isConnected(_ peer: MCPeerID) -> Bool {
        sessions.contains { $0.connectedPeers.contains(peer) }
    }

    /// Called on the main actor with each message from the room. The token
    /// takes the handler off again.
    func listen(_ handler: @escaping (Message) -> Void) -> UUID {
        let token = UUID()
        handlers[token] = handler
        return token
    }

    func unlisten(_ token: UUID) {
        handlers[token] = nil
    }

    fileprivate func received(_ data: Data) {
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
        for handler in handlers.values { handler(message) }
    }

    fileprivate func refreshPeers() {
        peers = sessions.flatMap(\.connectedPeers).map(\.displayName).sorted()
    }
}

extension RehearsalLink: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in self.refreshPeers() }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.received(data) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String,
                             fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension RehearsalLink: MCNearbyServiceAdvertiserDelegate {
    /// Only the team: the inviter says which team in the invitation.
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let theirs = context.flatMap { String(data: $0, encoding: .utf8) }
        Task { @MainActor in
            let room = theirs == self.team ? self.roomySession() : nil
            invitationHandler(room != nil, room)
        }
    }
}

extension RehearsalLink: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            // Same team, and one of the two invites — the one whose instance
            // sorts first — or both would, and the two half-connections
            // cancel out.
            guard info?["team"] == self.team, let theirs = info?["id"], self.instance < theirs,
                  !self.isConnected(peerID), let session = self.roomySession() else { return }
            browser.invitePeer(peerID, to: session, withContext: Data(self.team.utf8), timeout: 15)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.refreshPeers() }
    }
}
