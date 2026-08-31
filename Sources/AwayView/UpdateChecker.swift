import Foundation

struct Release: Equatable {
    let version: AppVersion
    let downloadURL: URL   // 配布 zip (AwayView-x.y.z.zip)
    let htmlURL: URL       // Releases ページ (更新を適用できないときの逃げ道)
}

// 「新版なし」と「確認できなかった」を nil に潰さない。
// v1.0.1 で ConnectionObserving を三値 enum にしたのと同じ理由。
enum UpdateCheckResult: Equatable {
    case upToDate
    case available(Release)
    case failed(String)
}

enum UpdateError: Error, LocalizedError {
    case http(Int)
    case emptyResponse
    case timedOut
    case process(String, Int32)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .emptyResponse: return "empty response"
        case .timedOut: return "timed out"
        case .process(let path, let status): return "\(path) exited with \(status)"
        }
    }
}

// ネットワークを差し替えるための seam。テストでは stub を刺す
protocol ReleaseFetching {
    func fetchLatestJSON() throws -> Data
}

struct GitHubReleaseFetcher: ReleaseFetching {
    static let latestURL = URL(string: "https://api.github.com/repos/wadap/awayview/releases/latest")!

    func fetchLatestJSON() throws -> Data {
        var request = URLRequest(url: Self.latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AwayView", forHTTPHeaderField: "User-Agent")
        return try URLSession.shared.awayviewSynchronousData(for: request)
    }
}

extension URLSession {
    /// URLSession に同期版が無いのでセマフォで待つ。**背景キュー専用** (main で呼ばない)
    func awayviewSynchronousData(for request: URLRequest) throws -> Data {
        var outcome: Result<Data, Error> = .failure(UpdateError.emptyResponse)
        let semaphore = DispatchSemaphore(value: 0)
        let task = dataTask(with: request) { data, response, error in
            if let error {
                outcome = .failure(error)
            } else if let http = response as? HTTPURLResponse,
                      !(200...299).contains(http.statusCode) {
                outcome = .failure(UpdateError.http(http.statusCode))
            } else if let data {
                outcome = .success(data)
            } else {
                outcome = .failure(UpdateError.emptyResponse)
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + request.timeoutInterval + 5) == .timedOut {
            task.cancel()
            throw UpdateError.timedOut
        }
        return try outcome.get()
    }
}

struct UpdateChecker {
    let fetcher: ReleaseFetching
    let currentVersion: AppVersion

    /// 同期。ネットワーク I/O を含むので呼び出し側が背景キューで回すこと
    func check() -> UpdateCheckResult {
        let data: Data
        do {
            data = try fetcher.fetchLatestJSON()
        } catch {
            return .failed(error.localizedDescription)
        }
        guard let release = Self.parse(data) else {
            return .failed("could not parse release metadata")
        }
        return release.version > currentVersion ? .available(release) : .upToDate
    }

    // /releases/latest は draft と prerelease を返さないので、その判定は持たない
    static func parse(_ data: Data) -> Release? {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let downloadURL: URL
                enum CodingKeys: String, CodingKey {
                    case name
                    case downloadURL = "browser_download_url"
                }
            }
            let tag: String
            let htmlURL: URL
            let assets: [Asset]
            enum CodingKeys: String, CodingKey {
                case tag = "tag_name"
                case htmlURL = "html_url"
                case assets
            }
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let version = AppVersion(payload.tag),
              let asset = payload.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            return nil
        }
        return Release(version: version, downloadURL: asset.downloadURL, htmlURL: payload.htmlURL)
    }
}
