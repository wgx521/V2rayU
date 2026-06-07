import Testing
import Foundation
@testable import V2rayU

struct PingRunningTests {

    // MARK: - Server Selection Logic

    /// 模拟多个同订阅服务器的 UUID
    private let subA = "sub-a-uuid"
    private let subB = "sub-b-uuid"
    private let svr1 = "svr-uuid-1"  // subA, speed=50
    private let svr2 = "svr-uuid-2"  // subA, speed=30
    private let svr3 = "svr-uuid-3"  // subA, speed=-1 (dead)
    private let svr4 = "svr-uuid-4"  // subB, speed=100
    private let svr5 = "svr-uuid-5"  // subB, speed=-1 (dead)

    private func makeProfile(uuid: String, subid: String, speed: Int, remark: String = "") -> ProfileEntity {
        ProfileEntity(uuid: uuid, remark: remark.isEmpty ? uuid : remark,
                      speed: speed, protocol: .vmess, address: "1.2.3.4", port: 443,
                      password: "test-id", subid: subid)
    }

    // MARK: - chooseNewServer prefers same-subscription servers

    @Test func selectBestPrefersFastestPingedInSameSub() {
        // Given: 当前 svr1(subA), 同订阅有 svr2(speed=30), svr3(speed=-1)
        // 不同订阅有 svr4(speed=100)
        let profiles = [
            makeProfile(uuid: svr1, subid: subA, speed: 50),
            makeProfile(uuid: svr2, subid: subA, speed: 30),
            makeProfile(uuid: svr3, subid: subA, speed: -1),
            makeProfile(uuid: svr4, subid: subB, speed: 100),
        ]

        let result = PingRunning.selectBestServer(
            from: profiles,
            currentUuid: svr1,
            currentSubId: subA
        )

        // Then: 应该选择同订阅中 ping 最快的 svr2 (30ms)，而不是不同订阅的 svr4
        #expect(result == svr2, "Should prefer fastest in same subscription, got \(result ?? "nil")")
    }

    @Test func selectBestFallsBackToOtherSubWhenSameSubEmpty() {
        // Given: 当前 svr1(subA, 唯一), 不同订阅有 svr4(speed=100)
        let profiles = [
            makeProfile(uuid: svr1, subid: subA, speed: 50),
            makeProfile(uuid: svr4, subid: subB, speed: 100),
        ]

        let result = PingRunning.selectBestServer(
            from: profiles,
            currentUuid: svr1,
            currentSubId: subA
        )

        // Then: 同订阅无备选，应选其他订阅的 (svr4)
        #expect(result == svr4, "Should fall back to other subscription")
    }

    @Test func selectBestRandomWhenNoPingedServers() {
        // Given: 所有备选 speed 都是 -1 (未测速)
        let profiles = [
            makeProfile(uuid: svr1, subid: subA, speed: 50),
            makeProfile(uuid: svr2, subid: subA, speed: -1),
            makeProfile(uuid: svr3, subid: subA, speed: -1),
        ]

        let result = PingRunning.selectBestServer(
            from: profiles,
            currentUuid: svr1,
            currentSubId: subA
        )

        // Then: 应该选一个（svr2 或 svr3），不能是 svr1
        #expect(result != nil)
        #expect(result != svr1)
        #expect(result == svr2 || result == svr3)
    }

    @Test func selectBestReturnsNilWhenNoCandidates() {
        // Given: 只有一个服务器且就是当前
        let profiles = [
            makeProfile(uuid: svr1, subid: subA, speed: 50),
        ]

        let result = PingRunning.selectBestServer(
            from: profiles,
            currentUuid: svr1,
            currentSubId: subA
        )

        // Then: 没有备选
        #expect(result == nil)
    }

    @Test func selectBestSkipsCurrentServer() {
        // Given: svr1 是当前，速度最快
        let profiles = [
            makeProfile(uuid: svr1, subid: subA, speed: 10),  // current, fastest
            makeProfile(uuid: svr2, subid: subA, speed: 50),
        ]

        let result = PingRunning.selectBestServer(
            from: profiles,
            currentUuid: svr1,
            currentSubId: subA
        )

        // Then: 不能选自己，应该选 svr2
        #expect(result == svr2, "Should skip current server even if it is fastest")
    }

    // MARK: - Subscription Dead Detection

    @Test func isSubscriptionAllDeadReturnsTrueWhenAllDead() {
        let profiles = [
            makeProfile(uuid: svr1, subid: subA, speed: -1),
            makeProfile(uuid: svr2, subid: subA, speed: -1),
            makeProfile(uuid: svr3, subid: subA, speed: 0),
        ]

        let result = PingRunning.isSubscriptionAllDead(profiles: profiles, subId: subA)
        #expect(result == true)
    }

    @Test func isSubscriptionAllDeadReturnsFalseWhenSomeWorking() {
        let profiles = [
            makeProfile(uuid: svr1, subid: subA, speed: -1),
            makeProfile(uuid: svr2, subid: subA, speed: 50),  // working!
            makeProfile(uuid: svr3, subid: subA, speed: -1),
        ]

        let result = PingRunning.isSubscriptionAllDead(profiles: profiles, subId: subA)
        #expect(result == false)
    }

    @Test func isSubscriptionAllDeadReturnsFalseWhenTooFewServers() {
        // 只有 2 个服务器，不触发刷新
        let profiles = [
            makeProfile(uuid: svr1, subid: subA, speed: -1),
            makeProfile(uuid: svr2, subid: subA, speed: -1),
        ]

        let result = PingRunning.isSubscriptionAllDead(
            profiles: profiles,
            subId: subA,
            minServerCount: 3
        )
        #expect(result == false, "Should not trigger refresh with fewer than minServerCount servers")
    }

    @Test func isSubscriptionAllDeadIgnoresOtherSubscriptions() {
        // 同订阅服务器全挂，但不同订阅有正常服务器
        let profiles = [
            makeProfile(uuid: svr1, subid: subA, speed: -1),
            makeProfile(uuid: svr2, subid: subA, speed: -1),
            makeProfile(uuid: svr3, subid: subA, speed: 0),
            makeProfile(uuid: svr4, subid: subB, speed: 100),  // different sub, working
            makeProfile(uuid: svr5, subid: subB, speed: 50),
        ]

        let result = PingRunning.isSubscriptionAllDead(profiles: profiles, subId: subA)
        #expect(result == true, "Should only check servers in the same subscription")
    }

    @Test func isSubscriptionAllDeadEmptySubIdReturnsFalse() {
        let profiles = [
            makeProfile(uuid: svr1, subid: "", speed: -1),
            makeProfile(uuid: svr2, subid: "", speed: -1),
            makeProfile(uuid: svr3, subid: "", speed: -1),
        ]

        let result = PingRunning.isSubscriptionAllDead(profiles: profiles, subId: "")
        #expect(result == false, "Empty subId should not trigger refresh")
    }

    // MARK: - Server Grouping by Subscription

    @Test func groupBySubscriptionSplitsCorrectly() {
        let profiles = [
            makeProfile(uuid: svr1, subid: subA, speed: 10),
            makeProfile(uuid: svr2, subid: subA, speed: 20),
            makeProfile(uuid: svr4, subid: subB, speed: 30),
        ]

        let (same, other) = PingRunning.groupBySubscription(
            profiles: profiles,
            currentUuid: svr1,
            currentSubId: subA
        )

        #expect(same.count == 1)    // svr2 (excludes svr1)
        #expect(other.count == 1)   // svr4
        #expect(same[0].uuid == svr2)
        #expect(other[0].uuid == svr4)
    }

    @Test func groupBySubscriptionHandlesEmptySubId() {
        let profiles = [
            makeProfile(uuid: svr1, subid: "", speed: 10),
            makeProfile(uuid: svr2, subid: "", speed: 20),
        ]

        let (same, other) = PingRunning.groupBySubscription(
            profiles: profiles,
            currentUuid: svr1,
            currentSubId: ""
        )

        // 空 subId 时全部归到 other
        #expect(same.isEmpty)
        #expect(other.count == 1)  // svr2
    }
}
