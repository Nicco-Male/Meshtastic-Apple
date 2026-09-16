import SwiftUI
import OSLog
import MeshtasticProtobufs

enum LocalStatsRequestTransport {
	case sharedChannel
	case remoteAdmin

	static func shouldChooseMethod(from: Int64, to: Int64) -> Bool {
		from != to
	}

	static func remoteAdminAvailable(for destinationPublicKey: Data?) -> Bool {
		destinationPublicKey?.count == 32
	}
}

enum TelemetryRequestKind: String, Identifiable {
	case deviceMetrics
	case localStats

	var id: String { rawValue }

	var title: String {
		switch self {
		case .deviceMetrics: return "Device Metrics"
		case .localStats: return "Local Stats"
		}
	}

	var requestTitle: String {
		switch self {
		case .deviceMetrics: return "Request Telemetry"
		case .localStats: return "Request Local Stats"
		}
	}

	var systemImage: String {
		switch self {
		case .deviceMetrics: return "waveform.path.ecg"
		case .localStats: return "chart.bar"
		}
	}

	var rateLimitKey: String {
		switch self {
		case .deviceMetrics: return "deviceMetricsRequest"
		case .localStats: return "localstats"
		}
	}
}

private struct TelemetryRequestSheet: Identifiable {
	let id = UUID()
	let kind: TelemetryRequestKind
}

struct RequestLocalStatsButton: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	@StateObject private var rateLimitStorage = RateLimitStorage.shared

	var node: NodeInfoEntity

	@State private var presentedSheet: TelemetryRequestSheet?
	@State private var sentRequest: TelemetryRequestKind?

	var body: some View {
		Group {
			telemetryButton(.deviceMetrics)
			telemetryButton(.localStats)
		}
		.alert(item: $sentRequest) { kind in
			Alert(
				title: Text("\(kind.title) Requested"),
				message: Text("A \(kind.title.lowercased()) request has been sent to \(node.user?.longName ?? "this node"). Responses can take some time."),
				dismissButton: .default(Text("OK"))
			)
		}
		.sheet(item: $presentedSheet) { sheet in
			TelemetryRequestMethodSheet(node: node, kind: sheet.kind) { kind in
				sentRequest = kind
			}
		}
	}

	@ViewBuilder
	private func telemetryButton(_ kind: TelemetryRequestKind) -> some View {
		let completion = rateLimitStorage.rateLimitRemainingPercentage(forKey: kind.rateLimitKey)
		let secondsRemaining = rateLimitStorage.rateLimitSecondsRemaining(forKey: kind.rateLimitKey)

		Button {
			request(kind)
		} label: {
			if completion > 0.0 {
				Label("\(kind.title) \(Int(secondsRemaining))s", systemImage: "clock")
			} else {
				Label(kind.requestTitle, systemImage: kind.systemImage)
			}
		}
		.disabled(completion > 0.0)
	}

	private func request(_ kind: TelemetryRequestKind) {
		let destination = node.user?.num ?? 0
		let source = accessoryManager.activeConnection?.device.num ?? 0
		if LocalStatsRequestTransport.shouldChooseMethod(from: source, to: destination) {
			presentedSheet = TelemetryRequestSheet(kind: kind)
		} else {
			send(kind, transport: .sharedChannel)
		}
	}

	private func send(_ kind: TelemetryRequestKind, transport: LocalStatsRequestTransport) {
		Task { @MainActor in
			do {
				try await accessoryManager.sendTelemetryRequest(
					kind: kind,
					destNum: node.user?.num ?? 0,
					wantResponse: true,
					transport: transport,
					destinationPublicKey: node.user?.publicKey
				)
				rateLimitStorage.actionOccured(forKey: kind.rateLimitKey, rateLimit: 30.0)
				sentRequest = kind
			} catch {
				Logger.mesh.warning("Failed to send \(kind.title, privacy: .public) request: \(error)")
			}
		}
	}
}

private struct TelemetryRequestMethodSheet: View {
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject private var accessoryManager: AccessoryManager

	let node: NodeInfoEntity
	let kind: TelemetryRequestKind
	let onSent: (TelemetryRequestKind) -> Void

	@State private var errorMessage: String?
	@State private var isSending = false

	private var destination: Int64 { node.user?.num ?? 0 }
	private var destinationPublicKey: Data? { node.user?.publicKey }
	private var directPKIAvailable: Bool {
		LocalStatsRequestTransport.remoteAdminAvailable(for: destinationPublicKey)
	}

	var body: some View {
		NavigationStack {
			List {
				Section("Send \(kind.title.lowercased()) request") {
					Text("Choose how to encrypt this request to \(node.user?.longName ?? "this node"). The request is addressed only to that node.")
						.foregroundStyle(.secondary)
				}

				Section {
					Button {
						send(transport: .sharedChannel)
					} label: {
						Label {
							VStack(alignment: .leading, spacing: 3) {
								Text("Shared channel")
								Text("Encrypt with the shared mesh channel. This is still a request to this node, not a channel-wide telemetry request.")
									.font(.footnote)
									.foregroundStyle(.secondary)
							}
						} icon: {
							Image(systemName: "person.2.fill")
						}
					}
					.disabled(isSending)

					Button {
						send(transport: .remoteAdmin)
					} label: {
						Label {
							VStack(alignment: .leading, spacing: 3) {
								Text("Direct PKI")
								Text(directPKIAvailable
									? "Encrypt directly to this node using its public key. Remote Admin permission is not required."
									: "Unavailable because this node has no public key.")
									.font(.footnote)
									.foregroundStyle(.secondary)
							}
						} icon: {
							Image(systemName: "lock.fill")
						}
					}
					.disabled(isSending || !directPKIAvailable)
				}
			}
			.navigationTitle("Encryption method")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
			}
			.alert("Couldn't send \(kind.title) request", isPresented: Binding(
				get: { errorMessage != nil },
				set: { if !$0 { errorMessage = nil } }
			)) {
				Button("OK") { errorMessage = nil }
			} message: {
				Text(errorMessage ?? "")
			}
		}
	}

	private func send(transport: LocalStatsRequestTransport) {
		isSending = true
		Task { @MainActor in
			do {
				try await accessoryManager.sendTelemetryRequest(
					kind: kind,
					destNum: destination,
					wantResponse: true,
					transport: transport,
					destinationPublicKey: destinationPublicKey
				)
				RateLimitStorage.shared.actionOccured(forKey: kind.rateLimitKey, rateLimit: 30.0)
				onSent(kind)
				dismiss()
			} catch {
				errorMessage = error.localizedDescription
				isSending = false
				Logger.mesh.warning("Failed to send \(kind.title, privacy: .public) request: \(error)")
			}
		}
	}
}

extension AccessoryManager {
	func sendTelemetryRequest(
		kind: TelemetryRequestKind,
		destNum: Int64,
		wantResponse: Bool,
		transport: LocalStatsRequestTransport = .sharedChannel,
		destinationPublicKey: Data? = nil
	) async throws {
		switch kind {
		case .localStats:
			try await sendLocalStatsRequest(
				destNum: destNum,
				wantResponse: wantResponse,
				transport: transport,
				destinationPublicKey: destinationPublicKey
			)
		case .deviceMetrics:
			try await sendDeviceMetricsRequest(
				destNum: destNum,
				wantResponse: wantResponse,
				transport: transport,
				destinationPublicKey: destinationPublicKey
			)
		}
	}

	private func sendDeviceMetricsRequest(
		destNum: Int64,
		wantResponse: Bool,
		transport: LocalStatsRequestTransport,
		destinationPublicKey: Data?
	) async throws {
		guard let fromNodeNum = activeConnection?.device.num else {
			Logger.services.error("Error while sending device metrics request. No active device.")
			throw AccessoryError.ioFailed("No active device")
		}

		var telemetryPacket = Telemetry()
		telemetryPacket.deviceMetrics = DeviceMetrics()

		var meshPacket = MeshPacket()
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.to = UInt32(destNum)
		meshPacket.from = UInt32(fromNodeNum)
		meshPacket.wantAck = true
		guard LocalStatsRequestTransport.configure(
			&meshPacket,
			transport: transport,
			destinationPublicKey: destinationPublicKey
		) else {
			throw AccessoryError.ioFailed("sendDeviceMetricsRequest: Direct PKI requires the destination public key")
		}

		var dataMessage = DataMessage()
		guard let serializedData = try? telemetryPacket.serializedData() else {
			throw AccessoryError.ioFailed("sendDeviceMetricsRequest: Unable to serialize telemetry packet")
		}
		dataMessage.payload = serializedData
		dataMessage.portnum = PortNum.telemetryApp
		dataMessage.wantResponse = wantResponse
		meshPacket.decoded = dataMessage

		var toRadio = ToRadio()
		toRadio.packet = meshPacket

		let logString = String.localizedStringWithFormat(
			"📊 Sent Device Metrics Request from: %@ to: %@".localized,
			String(fromNodeNum),
			String(destNum)
		)
		try await send(toRadio, debugDescription: logString)
		Logger.mesh.info("📊 \(logString, privacy: .public)")
	}
}