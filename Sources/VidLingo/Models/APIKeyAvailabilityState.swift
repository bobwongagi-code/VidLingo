struct APIKeyAvailabilityState {
    private(set) var value = KeychainAvailability.missing
    private var revision = 0

    mutating func beginRefresh(reset: Bool) -> Int {
        revision += 1
        if reset {
            value = .missing
        }
        return revision
    }

    mutating func set(_ value: KeychainAvailability) {
        revision += 1
        self.value = value
    }

    mutating func apply(_ value: KeychainAvailability, revision: Int) {
        // 保存、删除或新查询开始后，旧查询不得覆盖当前密钥状态。
        guard self.revision == revision else { return }
        self.value = value
    }
}
