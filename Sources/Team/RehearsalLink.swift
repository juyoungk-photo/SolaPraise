//
//  RehearsalLink.swift
//  SolaPraise
//
//  The team's devices in one room, talking directly — Wi-Fi or Bluetooth,
//  no internet — while a chart is open: a chord fixed on one stand is on
//  every other stand in the room at once.
//
//  WHY: in rehearsal the leader fixes the bridge and the band is reading
//  it the same moment. Only the change goes (ChartDelta), straight to the
//  devices nearby — no sheet, no Drive, no internet. Members not in the
//  room get the chart afterwards as a PDF, corrections and drawings in it.
//
//  EIGHT DEVICES: one session, as MultipeerConnectivity holds them — eight
//  at most, this one among them. A ninth is told the room is full rather
//  than left wondering.
//
//  ONE READING FOR THE ROOM: each device reads a chart's chords on its
//  own, and two readings of one page can differ — a chord one finds the
//  other does not — so a change could fall on nothing. A device opening a
//  chart with someone nearby asks for theirs first (`want`), takes their
//  chords whole (`chords`), and reads for itself only when nobody answers.
//  A change that still does not fit asks again. Where two stands come with
//  different charts, the one corrected last is the room's (`digest`).
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
    /// The team is in the room nearby, eight devices already, and this one
    /// is not among them.
    @Published private(set) var roomFull = false

    /// MultipeerConnectivity's limit for one session, this device included.
    static let roomSize = 8

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
            /// 「This is the chart I have」, as a digest and when it was last
            /// corrected: sent when a chart is open and the room changes, so
            /// two stands that came with different charts find out, and the
            /// one corrected earlier takes the other's.
            case digest
            /// One member's drawing on a chart, all of it (ScoreInk).
            case ink
            /// 「I am leading — here」: the chart and page the leader is on,
            /// as they turn it and every two seconds besides, so a stand
            /// that comes in later finds them, and one that stops hearing
            /// them stops following.
            case lead
            /// The leader has stopped leading.
            case leadEnd
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
        /// For `digest` and `chords`: when the chart was last corrected by
        /// hand, on any stand — nil when it never was.
        var corrected: Date? = nil
        /// For `digest` and `chords`: the key the chart is taken to be in,
        /// as a root (0 = C), so every stand transposes it by the same step.
        var root: Int? = nil
        /// The device it is from, and — for an answer or a request meant for
        /// one device — the device it is for.
        var sender: String = ""
        var to: String? = nil
        /// Whose drawing, for `ink`: the same on all of one member's devices.
        var author: String? = nil
        /// For `ink`: the page just drawn on, as PencilKit drew it — every
        /// stand in the room shows it as drawn, not as the XFDF line.
        var page: Int? = nil
        var rich: RichPage? = nil
        /// Who fixed it, for the line that says so.
        var from: String
        /// When it left the sender — for the debug log's latency.
        var sentAt: Date? = nil
    }

    /// Binary, not JSON: a drawing's data goes as it is rather than a
    /// third larger in base64, and is quicker to write and read.
    private static let encoder: PropertyListEncoder = {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }()

    /// 「sp-rehearsal」: Bonjour's service type, as in Info.plist.
    private static let service = "sp-rehearsal"

    private var me: MCPeerID?
    private var instance = UUID().uuidString
    private var session: MCSession?
    /// Devices invited and not yet connected, held a place for: two found
    /// at once must not both be let into the last place.
    private var invited: Set<MCPeerID> = []
    private var advertiser: MCNearbyServiceAdvertiser?
    /// What the advertiser says now: whether this room is full.
    private var advertisingFull = false
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
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session
        advertise(full: false)
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
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        invited = []
        peers = []
        roomFull = false
    }

    /// This device, as the room knows it.
    var me_: String { instance }

    /// To every device connected, at once and in order.
    func send(_ message: Message) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        var message = message
        message.sender = instance
        message.sentAt = Date()
        guard let data = try? Self.encoder.encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
        #if DEBUG
        NSLog("[Room] sent \(message.kind.rawValue) \(data.count)B to \(session.connectedPeers.count)")
        #endif
    }

    /// Says who this is — and, when its room has eight, that it is full,
    /// so a ninth device can say why it is not joining.
    private func advertise(full: Bool) {
        guard let me else { return }
        advertiser?.stopAdvertisingPeer()
        var info = ["team": team, "id": instance]
        if full { info["full"] = "1" }
        let advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: info, serviceType: Self.service)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        advertisingFull = full
    }

    /// A place for one more device: this one and every other connected or
    /// on its way, fewer than eight.
    fileprivate func hasRoom(for peer: MCPeerID) -> Bool {
        guard let session else { return false }
        let taken = Set(session.connectedPeers).union(invited)
        return taken.contains(peer) || taken.count + 1 < Self.roomSize
    }

    fileprivate func isConnected(_ peer: MCPeerID) -> Bool {
        session?.connectedPeers.contains(peer) ?? false
    }

    fileprivate func found(_ peer: MCPeerID, info: [String: String]?) {
        guard info?["team"] == team, let theirs = info?["id"] else { return }
        // Their room is full and this device is in no room: told so.
        if info?["full"] == "1", peers.isEmpty { roomFull = true }
        // One of the two invites — the one whose instance sorts first — or
        // both would, and the two half-connections cancel out.
        guard instance < theirs, !isConnected(peer), hasRoom(for: peer), let session else { return }
        invited.insert(peer)
        browser?.invitePeer(peer, to: session, withContext: Data(team.utf8), timeout: 15)
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
        guard let message = try? PropertyListDecoder().decode(Message.self, from: data) else { return }
        #if DEBUG
        let ms = message.sentAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        NSLog("[Room] got \(message.kind.rawValue) \(data.count)B in \(ms)ms")
        #endif
        for handler in handlers.values { handler(message) }
    }

    fileprivate func refreshPeers() {
        let connected = session?.connectedPeers ?? []
        invited.subtract(connected)
        // By name: a stand that restarted is a new peer at once, and the
        // old one lingers a few seconds before it times out — counted
        // once, not twice.
        peers = Array(Set(connected.map(\.displayName))).sorted()
        #if DEBUG
        NSLog("[Room] peers \(peers.count) (sessions \(connected.count), invited \(invited.count))")
        #endif
        if !peers.isEmpty { roomFull = false }
        let full = connected.count + 1 >= Self.roomSize
        if full != advertisingFull { advertise(full: full) }
    }

    fileprivate func settled(_ peer: MCPeerID) {
        invited.remove(peer)
        refreshPeers()
    }
}

extension RehearsalLink: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            if state == .connecting { self.refreshPeers() } else { self.settled(peerID) }
        }
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
            // Only the team, and only while there is a place.
            guard theirs == self.team, self.hasRoom(for: peerID), let session = self.session else {
                invitationHandler(false, nil)
                return
            }
            self.invited.insert(peerID)
            invitationHandler(true, session)
        }
    }
}

extension RehearsalLink: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in self.found(peerID, info: info) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.refreshPeers() }
    }
}
