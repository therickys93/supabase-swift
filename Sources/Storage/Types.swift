import Foundation

public struct SearchOptions: Encodable, Sendable {
  var prefix: String

  /// The number of files you want to be returned.
  public var limit: Int?

  /// The starting position.
  public var offset: Int?

  /// The column to sort by. Can be any column inside a ``FileObject``.
  public var sortBy: SortBy?

  /// The search string to filter files by.
  public var search: String?

  public init(
    limit: Int? = nil,
    offset: Int? = nil,
    sortBy: SortBy? = nil,
    search: String? = nil
  ) {
    prefix = ""
    self.limit = limit
    self.offset = offset
    self.sortBy = sortBy
    self.search = search
  }
}

public struct SortBy: Encodable, Sendable {
  public var column: String?
  public var order: String?

  public init(column: String? = nil, order: String? = nil) {
    self.column = column
    self.order = order
  }
}

public struct FileOptions: Sendable {
  /// The number of seconds the asset is cached in the browser and in the Supabase CDN. This is set
  /// in the `Cache-Control: max-age=<seconds>` header. Defaults to 3600 seconds.
  public var cacheControl: String

  /// The `Content-Type` header value.
  public var contentType: String?

  /// When upsert is set to true, the file is overwritten if it exists. When set to false, an error
  /// is thrown if the object already exists. Defaults to false.
  public var upsert: Bool

  /// The duplex option is a string parameter that enables or disables duplex streaming, allowing
  /// for both reading and writing data in the same stream. It can be passed as an option to the
  /// fetch() method.
  public var duplex: String?

  public init(
    cacheControl: String = "3600",
    contentType: String? = nil,
    upsert: Bool = false,
    duplex: String? = nil
  ) {
    self.cacheControl = cacheControl
    self.contentType = contentType
    self.upsert = upsert
    self.duplex = duplex
  }
}

public struct SignedURL: Decodable, Sendable {
  /// An optional error message.
  public var error: String?

  /// The signed url.
  public var signedURL: URL

  /// The path of the file.
  public var path: String

  public init(error: String? = nil, signedURL: URL, path: String) {
    self.error = error
    self.signedURL = signedURL
    self.path = path
  }
}

public struct SignedUploadURL: Sendable {
  public let signedURL: URL
  public let path: String
  public let token: String
}

public struct FileUploadResponse: Sendable {
  public let id: String
  public let path: String
  public let fullPath: String
}

public struct SignedURLUploadResponse: Sendable {
  public let path: String
  public let fullPath: String
}

public struct CreateSignedUploadURLOptions: Sendable {
  public var upsert: Bool

  public init(upsert: Bool) {
    self.upsert = upsert
  }
}

public struct DestinationOptions: Sendable {
  public var destinationBucket: String?

  public init(destinationBucket: String? = nil) {
    self.destinationBucket = destinationBucket
  }
}
