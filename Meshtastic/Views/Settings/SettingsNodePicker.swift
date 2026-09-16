import Foundation
import SwiftData
import SwiftUI

/// Searchable replacement for the old navigation-link Picker used by Settings > Configure.
/// The caller supplies nodes in priority order (connected, Remote Admin ready, favorites, alpha),
/// so filtering never changes the intended ranking.
struct SettingsNodePicker: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.modelContext) private var context
	@EnvironmentObject private var accessoryManager: AccessoryManager

	let nodes: [SettingsNodeSnapshot]
	@Binding var selectedNode: Int
	@State private var searchText = ""
	@State private var pendingNode: SettingsNodeSnapshot?
	@State private var showingConfigurationChoice = false
	@State private var refreshProgress: FullConfigProgress?
	@State private var refreshAlert: FullConfigAlert?

	private struct FullConfigProgress {
		var sent = 0
		var total = 0
		var loaded = 0
		var sendFailures = 0
		var phase: Phase = .sending

		enum Phase {
			case sending
			case waiting
			case success
			case partial
		}
	}

	private struct FullConfigAlert: Identifiable {
		let id = UUID()
		let title: String
		let message: String
	}

	private enum ConfigRequestItem: CaseIterable {
		case device
		case display
		case network
		case position
		case power
		case security
		case bluetooth
		case lora
		case ambientLighting
		case audio
		case cannedMessages
		case detectionSensor
		case externalNotification
		case mqtt
		case neighborInfo
		case rangeTest
		case paxCounter
		case serial
		case storeForward
		case telemetry

		var title: String {
			switch self {
			case .device: return "Device"
			case .display: return "Display"
			case .network: return "Network"
			case .position: return "Position"
			case .power: return "Power"
			case .security: return "Security"
			case .bluetooth: return "Bluetooth"
			case .lora: return "LoRa"
			case .ambientLighting: return "Ambient Lighting"
			case .audio: return "Audio"
			case .cannedMessages: return "Canned Messages"
			case .detectionSensor: return "Detection Sensor"
			case .externalNotification: return "External Notification"
			case .mqtt: return "MQTT"
			case .neighborInfo: return "Neighbor Info"
			case .rangeTest: return "Range Test"
			case .paxCounter: return "PAX Counter"
			case .serial: return "Serial"
			case .storeForward: return "Store & Forward"
			case .telemetry: return "Telemetry"
			}
		}
	}

	private var filteredNodes: [SettingsNodeSnapshot] {
		let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return nodes }

		return nodes.filter { node in
			let longName = node.userLongName ?? ""
			let shortName = node.userShortName ?? ""
			let decimalNodeNum = String(node.num)
			let hexNodeNum = String(format: "!%08x", UInt32(truncatingIfNeeded: node.num))
			return longName.localizedCaseInsensitiveContains(query)
				|| shortName.localizedCaseInsensitiveContains(query)
				|| decimalNodeNum.localizedCaseInsensitiveContains(query)
				|| hexNodeNum.localizedCaseInsensitiveContains(query)
		}
	}

	var body: some View {
		List {
			if let progress = refreshProgress {
				Section("Configuration Download") {
					refreshProgressRow(progress)
				}
			}

			ForEach(filteredNodes) { node in
				Button {
					handleNodeSelection(node)
				} label: {
					HStack(spacing: 12) {
						nodeLabel(node)
						Spacer()
						if selectedNode == Int(node.num) {
							Image(systemName: "checkmark")
								.foregroundStyle(.tint)
						}
					}
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.disabled(refreshProgress?.phase == .sending || refreshProgress?.phase == .waiting)
			}

			if filteredNodes.isEmpty {
				Text("No matching nodes")
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .center)
			}
		}
		.searchable(text: $searchText, prompt: "Search nodes")
		.navigationTitle("Configure Node")
		.navigationBarTitleDisplayMode(.inline)
		.confirmationDialog(
			"Load configuration",
			isPresented: $showingConfigurationChoice,
			titleVisibility: .visible
		) {
			Button("Download Full Configuration") {
				guard let node = pendingNode else { return }
				selectedNode = Int(node.num)
				Task { @MainActor in
					await downloadFullConfiguration(for: node)
				}
			}
			Button("Partial / On Demand") {
				guard let node = pendingNode else { return }
				selectPartial(node)
			}
			Button("Cancel", role: .cancel) { }
		} message: {
			Text("Full requests all supported configuration sections now. Partial keeps the current iOS behavior and loads sections only when you open them.")
		}
		.alert(item: $refreshAlert) { alert in
			Alert(
				title: Text(alert.title),
				message: Text(alert.message),
				dismissButton: .default(Text("Continue")) {
					dismiss()
				}
			)
		}
	}

	private func handleNodeSelection(_ node: SettingsNodeSnapshot) {
		let activeNode = Int64(accessoryManager.activeDeviceNum ?? 0)
		if node.num == activeNode {
			selectPartial(node)
			return
		}

		let remoteAdminReady: Bool
		if UserDefaults.enableAdministration {
			remoteAdminReady = node.canRemoteAdmin && node.hasSessionPasskey
		} else {
			remoteAdminReady = node.hasMetadata
		}

		guard remoteAdminReady else {
			// A PKI session must be established first. Reuse the existing Settings flow,
			// which requests metadata/session setup when selectedNode changes.
			selectPartial(node)
			return
		}

		pendingNode = node
		showingConfigurationChoice = true
	}

	private func selectPartial(_ node: SettingsNodeSnapshot) {
		selectedNode = Int(node.num)
		dismiss()
	}

	@ViewBuilder
	private func refreshProgressRow(_ progress: FullConfigProgress) -> some View {
		switch progress.phase {
		case .sending:
			Label {
				VStack(alignment: .leading, spacing: 3) {
					Text("Request Sent")
					Text("Sending \(progress.sent) of \(progress.total) configuration requests")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			} icon: {
				ProgressView()
			}
		case .waiting:
			Label {
				VStack(alignment: .leading, spacing: 3) {
					Text("Waiting for responses")
					Text("Loaded \(progress.loaded) of \(progress.total) sections")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			} icon: {
				ProgressView()
			}
		case .success:
			Label {
				VStack(alignment: .leading, spacing: 3) {
					Text("Config Updated")
					Text("Loaded \(progress.loaded) of \(progress.total) sections")
						.font(.footnote)
				}
			} icon: {
				Image(systemName: "checkmark.circle.fill")
			}
			.foregroundStyle(.green)
		case .partial:
			Label {
				VStack(alignment: .leading, spacing: 3) {
					Text("Partial / Timed Out")
					Text("Loaded \(progress.loaded) of \(progress.total) sections; \(progress.sendFailures) send failures")
						.font(.footnote)
				}
			} icon: {
				Image(systemName: "exclamationmark.triangle.fill")
			}
			.foregroundStyle(.orange)
		}
	}

	@MainActor
	private func downloadFullConfiguration(for snapshot: SettingsNodeSnapshot) async {
		guard let activeNodeNum = accessoryManager.activeDeviceNum,
			let sourceNode = getNodeInfo(id: Int64(activeNodeNum), context: context),
			let fromUser = sourceNode.user,
			let destinationNode = getNodeInfo(id: snapshot.num, context: context),
			let toUser = destinationNode.user else {
			refreshProgress = FullConfigProgress(sent: 0, total: 0, loaded: 0, sendFailures: 1, phase: .partial)
			refreshAlert = FullConfigAlert(
				title: "Partial / Timed Out",
				message: "The source or destination node is no longer available."
			)
			return
		}

		let items = configurationItems(for: snapshot)
		let requestStartedAt = Date()
		var sent = 0
		var failures = 0
		refreshProgress = FullConfigProgress(sent: 0, total: items.count, loaded: 0, sendFailures: 0, phase: .sending)

		for item in items {
			guard !Task.isCancelled else { return }
			do {
				try await sendConfigurationRequest(item, fromUser: fromUser, toUser: toUser)
				sent += 1
			} catch {
				failures += 1
			}

			let liveNode = getNodeInfo(id: snapshot.num, context: context)
			let loaded = liveNode.map { loadedCount(items, node: $0) } ?? 0
			refreshProgress = FullConfigProgress(
				sent: sent,
				total: items.count,
				loaded: loaded,
				sendFailures: failures,
				phase: .sending
			)
			try? await Task.sleep(for: .milliseconds(350))
		}

		let timeout = Date().addingTimeInterval(25)
		while Date() < timeout, !Task.isCancelled {
			guard let liveNode = getNodeInfo(id: snapshot.num, context: context) else { break }
			let loaded = loadedCount(items, node: liveNode)
			let receivedFreshPacket = (liveNode.lastHeard ?? .distantPast) >= requestStartedAt.addingTimeInterval(-2)

			if loaded == items.count, failures == 0, receivedFreshPacket {
				refreshProgress = FullConfigProgress(
					sent: sent,
					total: items.count,
					loaded: loaded,
					sendFailures: failures,
					phase: .success
				)
				refreshAlert = FullConfigAlert(
					title: "Config Updated",
					message: "All \(items.count) requested configuration sections were loaded from \(snapshot.userLongName ?? "this node")."
				)
				return
			}

			refreshProgress = FullConfigProgress(
				sent: sent,
				total: items.count,
				loaded: loaded,
				sendFailures: failures,
				phase: .waiting
			)
			try? await Task.sleep(for: .seconds(1))
		}

		let finalLoaded = getNodeInfo(id: snapshot.num, context: context).map { loadedCount(items, node: $0) } ?? 0
		refreshProgress = FullConfigProgress(
			sent: sent,
			total: items.count,
			loaded: finalLoaded,
			sendFailures: failures,
			phase: .partial
		)
		refreshAlert = FullConfigAlert(
			title: "Partial / Timed Out",
			message: "Loaded \(finalLoaded) of \(items.count) requested sections. Open any missing section to request it again on demand."
		)
	}

	private func configurationItems(for snapshot: SettingsNodeSnapshot) -> [ConfigRequestItem] {
		var items: [ConfigRequestItem] = [
			.device, .display, .network, .position, .power, .security, .bluetooth, .lora
		]

		func include(_ item: ConfigRequestItem, when module: ExcludedModules) {
			if snapshot.excludedModules & module.rawValue == 0 {
				items.append(item)
			}
		}

		include(.ambientLighting, when: .ambientlightingConfig)
		include(.audio, when: .audioConfig)
		include(.cannedMessages, when: .cannedmsgConfig)
		include(.detectionSensor, when: .detectionsensorConfig)
		include(.externalNotification, when: .extnotifConfig)
		include(.mqtt, when: .mqttConfig)
		include(.neighborInfo, when: .neighborinfoConfig)
		include(.rangeTest, when: .rangetestConfig)
		include(.paxCounter, when: .paxcounterConfig)
		include(.serial, when: .serialConfig)
		include(.storeForward, when: .storeforwardConfig)
		include(.telemetry, when: .telemetryConfig)
		return items
	}

	@MainActor
	private func sendConfigurationRequest(
		_ item: ConfigRequestItem,
		fromUser: UserEntity,
		toUser: UserEntity
	) async throws {
		switch item {
		case .device:
			try await accessoryManager.requestDeviceConfig(fromUser: fromUser, toUser: toUser)
		case .display:
			try await accessoryManager.requestDisplayConfig(fromUser: fromUser, toUser: toUser)
		case .network:
			try await accessoryManager.requestNetworkConfig(fromUser: fromUser, toUser: toUser)
		case .position:
			try await accessoryManager.requestPositionConfig(fromUser: fromUser, toUser: toUser)
		case .power:
			try await accessoryManager.requestPowerConfig(fromUser: fromUser, toUser: toUser)
		case .security:
			try await accessoryManager.requestSecurityConfig(fromUser: fromUser, toUser: toUser)
		case .bluetooth:
			try await accessoryManager.requestBluetoothConfig(fromUser: fromUser, toUser: toUser)
		case .lora:
			try await accessoryManager.requestLoRaConfig(fromUser: fromUser, toUser: toUser)
		case .ambientLighting:
			try await accessoryManager.requestAmbientLightingConfig(fromUser: fromUser, toUser: toUser)
		case .audio:
			try await accessoryManager.requestAudioModuleConfig(fromUser: fromUser, toUser: toUser)
		case .cannedMessages:
			try await accessoryManager.requestCannedMessagesModuleConfig(fromUser: fromUser, toUser: toUser)
		case .detectionSensor:
			try await accessoryManager.requestDetectionSensorModuleConfig(fromUser: fromUser, toUser: toUser)
		case .externalNotification:
			try await accessoryManager.requestExternalNotificationModuleConfig(fromUser: fromUser, toUser: toUser)
		case .mqtt:
			try await accessoryManager.requestMqttModuleConfig(fromUser: fromUser, toUser: toUser)
		case .neighborInfo:
			try await accessoryManager.requestNeighborInfoModuleConfig(fromUser: fromUser, toUser: toUser)
		case .rangeTest:
			try await accessoryManager.requestRangeTestModuleConfig(fromUser: fromUser, toUser: toUser)
		case .paxCounter:
			try await accessoryManager.requestPaxCounterModuleConfig(fromUser: fromUser, toUser: toUser)
		case .serial:
			try await accessoryManager.requestSerialModuleConfig(fromUser: fromUser, toUser: toUser)
		case .storeForward:
			try await accessoryManager.requestStoreAndForwardModuleConfig(fromUser: fromUser, toUser: toUser)
		case .telemetry:
			try await accessoryManager.requestTelemetryModuleConfig(fromUser: fromUser, toUser: toUser)
		}
	}

	private func loadedCount(_ items: [ConfigRequestItem], node: NodeInfoEntity) -> Int {
		items.reduce(into: 0) { count, item in
			if isLoaded(item, node: node) {
				count += 1
			}
		}
	}

	private func isLoaded(_ item: ConfigRequestItem, node: NodeInfoEntity) -> Bool {
		switch item {
		case .device: return node.deviceConfig != nil
		case .display: return node.displayConfig != nil
		case .network: return node.networkConfig != nil
		case .position: return node.positionConfig != nil
		case .power: return node.powerConfig != nil
		case .security: return node.securityConfig != nil
		case .bluetooth: return node.bluetoothConfig != nil
		case .lora: return node.loRaConfig != nil
		case .ambientLighting: return node.ambientLightingConfig != nil
		case .audio: return node.audioConfig != nil
		case .cannedMessages: return node.cannedMessageConfig != nil
		case .detectionSensor: return node.detectionSensorConfig != nil
		case .externalNotification: return node.externalNotificationConfig != nil
		case .mqtt: return node.mqttConfig != nil
		case .neighborInfo: return node.neighborInfoConfig != nil
		case .rangeTest: return node.rangeTestConfig != nil
		case .paxCounter: return node.paxCounterConfig != nil
		case .serial: return node.serialConfig != nil
		case .storeForward: return node.storeForwardConfig != nil
		case .telemetry: return node.telemetryConfig != nil
		}
	}

	@ViewBuilder
	private func nodeLabel(_ node: SettingsNodeSnapshot) -> some View {
		if node.num == accessoryManager.activeDeviceNum ?? 0 {
			Label {
				Text("Connected") + Text(verbatim: ": \(node.userLongName?.addingVariationSelectors ?? "Unknown".localized)")
			} icon: {
				accessoryManager.activeConnection?.device.transportType.icon
					?? Image(systemName: "questionmark.circle")
			}
		} else if node.canRemoteAdmin && UserDefaults.enableAdministration && node.hasSessionPasskey {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text(node.userLongName?.addingVariationSelectors ?? "Unknown".localized)
					Text("Remote PKI Admin")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			} icon: {
				Image(systemName: "av.remote")
			}
		} else if !UserDefaults.enableAdministration && node.hasMetadata {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text(node.userLongName?.addingVariationSelectors ?? "Unknown".localized)
					Text("Remote Legacy Admin")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			} icon: {
				Image(systemName: "av.remote")
			}
		} else if UserDefaults.enableAdministration && node.userIsPkiEncrypted {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text(node.userLongName?.addingVariationSelectors ?? "Unknown".localized)
					Text("Request PKI Admin")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			} icon: {
				Image(systemName: "rectangle.and.hand.point.up.left")
			}
		} else {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text(node.userLongName?.addingVariationSelectors ?? "Unknown".localized)
					if let shortName = node.userShortName, !shortName.isEmpty {
						Text(shortName)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
			} icon: {
				Image(systemName: "circle")
			}
		}
	}
}
