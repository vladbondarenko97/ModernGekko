// Cloud saves (a save server, see save_sync.mm).
#pragma once

#include <filesystem>
#include <string>

namespace savesync
{
// Once, before the game reads its saves: brings newer saves into `folder` (a
// few seconds at most when the server doesn't answer), then uploads changes
// from a thread of its own. No documents/save_sync.txt: no sync.
void Start(const std::filesystem::path& documents, const std::filesystem::path& folder);
bool Started();
// The device's login: documents/save_sync.txt exists.
bool Configured(const std::filesystem::path& documents);
// Asks the server (space-separated URLs: the first that answers) whether the
// login works: "" when it does, else why not. Blocks up to ~10 s per URL.
std::string CheckLogin(const std::string& urls, const std::string& device, const std::string& password);
// Writes documents/save_sync.txt (owner-only).
bool SaveLogin(const std::filesystem::path& documents, const std::string& urls, const std::string& device,
               const std::string& password);
#if defined(__APPLE__) && !defined(IPHONEOS)
// Mac, first launch with no login: a form (server, device, password; "Not
// now" asks again next launch, "Never" writes save_sync.off). Main thread.
void PromptLoginIfNeeded(const std::filesystem::path& documents);
#endif
}  // namespace savesync
