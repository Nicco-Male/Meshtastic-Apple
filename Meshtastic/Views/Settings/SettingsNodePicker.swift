import Foundation
import SwiftUI

/// Searchable replacement for the old navigation-link Picker used by Settings > Configure.
/// The caller supplies nodes in priority order (connected, Remote Admin ready, favorites, alpha),
/// so filtering never changes the intended ranking.
struct SettingsNodePicker: View {
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject private var accessoryManager: AccessoryManager

	let nodes: [SettingsNodeSnapshot]
	@Binding var selectedNode: Int
	@State private var searchText = ""

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
			ForEach(filteredNodes) { node in
				Button {
					selectedNode = Int(node.num)
					dismiss()
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
