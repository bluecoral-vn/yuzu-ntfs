// SPDX-License-Identifier: GPL-2.0-only
import FSKit

@main
struct YuzuNTFSExtension: UnaryFileSystemExtension {
    let fileSystem = YuzuNTFSFileSystem()
}
