// Cloud saves: the memory card's folder (Dolphin's GCI folder, one .gci per save) kept in
// step across the player's devices, as game "sims2pets". Configured by
// save_sync.txt in the app's Documents, three lines: the server's URL (or
// several, space-separated, in order of preference: the next is used while
// one doesn't answer), this device's name, its password.
// No file: no sync. At start, server copies newer than the local ones come
// down before the game reads its saves; then a thread uploads a save a few
// seconds after the game last wrote it (a 409, the server's copy is newer:
// that one comes down instead). Offline, nothing waits more than a few
// seconds and the game plays on its local saves.
#include "save_sync.h"

#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#endif
#include <sys/stat.h>

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace fs = std::filesystem;

namespace
{
    constexpr const char* kGame = "sims2pets";
    std::vector<std::string> s_urls;  // the servers, in order of preference
    size_t s_current = 0;             // the one in use
    NSString* s_base = nil;           // s_urls[s_current]/v1/<game>/
    NSString* s_auth = nil;  // the Authorization header
    fs::path s_folder;
    bool s_started = false;
    std::map<std::string, fs::file_time_type> s_synced;  // each file's write time when last in step (watcher thread)

    // One request, waited for (at most `timeout` seconds). Returns the status (0: no answer).
    int Request(NSString* method, NSString* name, NSData* body, NSDictionary* headers, double timeout, NSData** data,
        NSHTTPURLResponse** response = nullptr)
    {
        NSString* escaped = [name stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
        NSMutableURLRequest* r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[s_base stringByAppendingString:escaped]]];
        r.HTTPMethod = method;
        r.HTTPBody = body;
        r.timeoutInterval = timeout;
        [r setValue:s_auth forHTTPHeaderField:@"Authorization"];
        for (NSString* k in headers)
            [r setValue:headers[k] forHTTPHeaderField:k];
        __block int status = 0;
        __block NSData* got = nil;
        __block NSHTTPURLResponse* resp = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        NSURLSessionDataTask* task = [NSURLSession.sharedSession dataTaskWithRequest:r
            completionHandler:^(NSData* d, NSURLResponse* u, NSError* e) {
                if (!e && [u isKindOfClass:NSHTTPURLResponse.class])
                {
                    resp = [(NSHTTPURLResponse*)u retain];
                    status = int(resp.statusCode);
                    got = [d retain];
                }
                dispatch_semaphore_signal(done);
            }];
        [task resume];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, int64_t((timeout + 1) * NSEC_PER_SEC))))
            [task cancel];
        if (data)
            *data = [got autorelease];
        else
            [got release];
        if (response)
            *response = [resp autorelease];
        else
            [resp release];
        return status;
    }

    std::string Sha256(const fs::path& p)
    {
        std::ifstream f(p, std::ios::binary);
        std::string bytes((std::istreambuf_iterator<char>(f)), {});
        unsigned char h[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(bytes.data(), CC_LONG(bytes.size()), h);
        char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
            snprintf(hex + 2 * i, 3, "%02x", h[i]);
        return hex;
    }

    int64_t UnixTime(fs::file_time_type t)
    {
        return std::chrono::duration_cast<std::chrono::seconds>(
            fs::file_time_type::clock::to_sys(t).time_since_epoch()).count();
    }

    // A save in a subfolder (save/<name>/<file>) goes by
    // one plain name on the server, its folders joined by "..": the server
    // takes no '/'. Empty when the name isn't a safe path below the save folder.
    std::string WireName(const fs::path& relative)
    {
        std::string name;
        for (const fs::path& part : relative)
            name += (name.empty() ? "" : "..") + part.string();
        return name;
    }

    fs::path LocalPath(const std::string& name)
    {
        fs::path relative;
        for (size_t b = 0;;)
        {
            const size_t e = name.find("..", b);
            const std::string part = name.substr(b, e == std::string::npos ? std::string::npos : e - b);
            if (part.empty() || part == ".")
                return {};
            relative /= part;
            if (e == std::string::npos)
                return relative;
            b = e + 2;
        }
    }

    // The server's copy of `name`, written over the local one (atomically, with the server's time).
    bool Download(const std::string& name)
    {
        NSData* data = nil;
        NSHTTPURLResponse* response = nil;
        if (Request(@"GET", @(name.c_str()), nil, nil, 15, &data, &response) != 200 || !data)
            return false;
        const fs::path relative = LocalPath(name);
        if (relative.empty())
            return false;
        const fs::path target = s_folder / relative, part = s_folder / (relative.string() + ".part");
        std::error_code ec;
        fs::create_directories(target.parent_path(), ec);
        {
            std::ofstream f(part, std::ios::binary | std::ios::trunc);
            f.write(static_cast<const char*>(data.bytes), std::streamsize(data.length));
            if (!f)
                return false;
        }
        if (NSString* mtime = [response valueForHTTPHeaderField:@"X-Mtime"])
            fs::last_write_time(part, fs::file_time_type::clock::from_sys(
                std::chrono::system_clock::time_point(std::chrono::seconds(mtime.longLongValue))), ec);
        fs::rename(part, target, ec);
        if (ec)
            return false;
        s_synced[name] = fs::last_write_time(target, ec);
        fprintf(stderr, "[sync] %s: the server's copy (newer) came down\n", name.c_str());
        return true;
    }

    void UseServer(size_t i)
    {
        s_current = i % s_urls.size();
        [s_base release];
        s_base = [[NSString alloc] initWithFormat:@"%s/v1/%s/", s_urls[s_current].c_str(), kGame];
    }

    void Pull()
    {
        NSData* data = nil;
        int status = 0;
        for (size_t i = 0; i < s_urls.size() && status != 200; i++)
        {
            UseServer(i);
            status = Request(@"GET", @"", nil, nil, 5, &data);
        }
        if (status != 200)
        {
            UseServer(0);
            fprintf(stderr, "[sync] no answer from the save servers (%d): playing on this device's saves\n", status);
            return;
        }
        fprintf(stderr, "[sync] using %s\n", s_urls[s_current].c_str());
        NSDictionary* listing = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![listing isKindOfClass:NSDictionary.class])
            return;
        for (NSString* key in listing)
        {
            const std::string name = key.UTF8String;
            NSDictionary* remote = listing[key];
            const fs::path relative = LocalPath(name);
            if (relative.empty())
                continue;
            const fs::path local = s_folder / relative;
            std::error_code ec;
            const bool have = fs::is_regular_file(local, ec);
            if (have && Sha256(local) == std::string([remote[@"sha256"] UTF8String]))
                continue;
            if (!have || [remote[@"mtime"] longLongValue] > UnixTime(fs::last_write_time(local, ec)))
                Download(name);
        }
    }

    void Watch()
    {
        for (;;)
        {
            std::this_thread::sleep_for(std::chrono::seconds(5));
            @autoreleasepool
            {
                std::error_code ec;
                const auto now = fs::file_time_type::clock::now();
                for (const fs::directory_entry& e : fs::recursive_directory_iterator(s_folder, ec))
                {
                    const std::string file = e.path().filename().string();
                    if (!e.is_regular_file(ec) || file.ends_with(".part") || file.starts_with("."))
                        continue;
                    const std::string name = WireName(e.path().lexically_relative(s_folder));
                    const fs::file_time_type written = e.last_write_time(ec);
                    // Changed since last in step, and left alone for 3 s (the game is done writing).
                    if (s_synced.count(name) && s_synced[name] == written)
                        continue;
                    if (now - written < std::chrono::seconds(3))
                        continue;
                    std::ifstream f(e.path(), std::ios::binary);
                    std::string bytes((std::istreambuf_iterator<char>(f)), {});
                    NSData* body = [NSData dataWithBytes:bytes.data() length:bytes.size()];
                    NSDictionary* headers = @{ @"X-Mtime" : [NSString stringWithFormat:@"%lld", (long long)UnixTime(written)] };
                    const int status = Request(@"PUT", @(name.c_str()), body, headers, 15, nullptr);
                    if (status == 200)
                    {
                        s_synced[name] = written;
                        fprintf(stderr, "[sync] %s: uploaded\n", name.c_str());
                    }
                    else if (status == 409)
                        Download(name);
                    else if (status == 0)
                    {
                        UseServer(s_current + 1);  // no answer: the next server on the next pass
                        break;
                    }
                }
            }
        }
    }
}

namespace savesync
{
    void Start(const std::filesystem::path& documents, const std::filesystem::path& folder)
    {
        @autoreleasepool
        {
            std::ifstream config(documents / "save_sync.txt");
            std::string url, device, password;
            if (!std::getline(config, url) || !std::getline(config, device) || !std::getline(config, password) || url.empty())
                return;
            std::istringstream urls(url);
            for (std::string u; urls >> u;)
            {
                while (!u.empty() && u.back() == '/')
                    u.pop_back();
                s_urls.push_back(u);
            }
            if (s_urls.empty())
                return;
            UseServer(0);
            NSData* credentials = [@((device + ":" + password).c_str()) dataUsingEncoding:NSUTF8StringEncoding];
            s_auth = [[NSString alloc] initWithFormat:@"Basic %@", [credentials base64EncodedStringWithOptions:0]];
            s_folder = folder;
            std::error_code ec;
            fs::create_directories(s_folder, ec);
            Pull();
            // Everything local now counts as in step with the server only once
            // uploaded: files the server never had go up on the first pass.
            fprintf(stderr, "[sync] saves synced with %s as %s\n", url.c_str(), device.c_str());
        }
        s_started = true;
        std::thread(Watch).detach();
    }

    bool Started() { return s_started; }

    bool Configured(const std::filesystem::path& documents)
    {
        std::error_code ec;
        return fs::is_regular_file(documents / "save_sync.txt", ec);
    }

    std::string CheckLogin(const std::string& urls, const std::string& device, const std::string& password)
    {
        @autoreleasepool
        {
            if (device.empty() || password.empty())
                return "Enter this device's name and password.";
            NSData* credentials = [@((device + ":" + password).c_str()) dataUsingEncoding:NSUTF8StringEncoding];
            NSString* auth = [NSString stringWithFormat:@"Basic %@", [credentials base64EncodedStringWithOptions:0]];
            std::istringstream list(urls);
            std::string why = "Enter the server's address.";
            for (std::string u; list >> u;)
            {
                while (!u.empty() && u.back() == '/')
                    u.pop_back();
                NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"%s/v1/%s/", u.c_str(), kGame]];
                if (!url || !url.host)
                {
                    why = "Not a web address: " + u;
                    continue;
                }
                NSMutableURLRequest* r = [NSMutableURLRequest requestWithURL:url];
                r.timeoutInterval = 10;
                [r setValue:auth forHTTPHeaderField:@"Authorization"];
                __block long status = 0;
                dispatch_semaphore_t done = dispatch_semaphore_create(0);
                [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData*, NSURLResponse* resp, NSError* e) {
                    if (!e && [resp isKindOfClass:NSHTTPURLResponse.class])
                        status = ((NSHTTPURLResponse*)resp).statusCode;
                    dispatch_semaphore_signal(done);
                }] resume];
                dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC));
                dispatch_release(done);
                if (status == 200)
                    return "";
                why = status == 401 ? "Wrong device name or password."
                    : status == 404 ? std::string("The server has no \"") + kGame + "\" game (add it there first)."
                    : status ? "The server answered " + std::to_string(status) + "."
                    : "No answer from " + u + ".";
                if (status == 401 || status == 404)
                    return why;
            }
            return why;
        }
    }

    bool SaveLogin(const std::filesystem::path& documents, const std::string& urls, const std::string& device,
                   const std::string& password)
    {
        std::error_code ec;
        fs::create_directories(documents, ec);
        const fs::path path = documents / "save_sync.txt";
        {
            std::ofstream f(path, std::ios::trunc);
            f << urls << "\n" << device << "\n" << password << "\n";
            if (!f)
                return false;
        }
        chmod(path.c_str(), 0600);
        return true;
    }

#if TARGET_OS_OSX
    void PromptLoginIfNeeded(const std::filesystem::path& documents)
    {
        std::error_code ec;
        if (Configured(documents) || fs::exists(documents / "save_sync.off", ec) || ![NSThread isMainThread])
            return;
        @autoreleasepool
        {
            [NSApplication sharedApplication];
            [NSApp activateIgnoringOtherApps:YES];
            NSTextField* url = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 64, 300, 24)] autorelease];
            NSTextField* device = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 32, 300, 24)] autorelease];
            NSSecureTextField* password = [[[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)] autorelease];
            url.placeholderString = @"Server, e.g. https://saves.example.com";
            device.placeholderString = @"This device's name";
            password.placeholderString = @"Password";
            device.stringValue = NSHost.currentHost.localizedName ?: @"";
            NSView* box = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 88)] autorelease];
            [box addSubview:url];
            [box addSubview:device];
            [box addSubview:password];
            NSString* message = @"Sign in to a save server to keep your memory card in step across your Macs and iOS devices.";
            for (;;)
            {
                NSAlert* alert = [[[NSAlert alloc] init] autorelease];
                alert.messageText = @"Cloud saves";
                alert.informativeText = message;
                alert.accessoryView = box;
                [alert addButtonWithTitle:@"Sign In"];
                [alert addButtonWithTitle:@"Not Now"];
                [alert addButtonWithTitle:@"Never"];
                alert.window.initialFirstResponder = url.stringValue.length ? password : url;
                const NSModalResponse choice = [alert runModal];
                if (choice == NSAlertThirdButtonReturn)
                {
                    std::ofstream(documents / "save_sync.off") << "delete this file to be asked to sign in again\n";
                    return;
                }
                if (choice != NSAlertFirstButtonReturn)
                    return;
                const std::string u = url.stringValue.UTF8String, d = device.stringValue.UTF8String,
                                  p = password.stringValue.UTF8String;
                const std::string why = CheckLogin(u, d, p);
                if (why.empty())
                {
                    SaveLogin(documents, u, d, p);
                    return;
                }
                message = [NSString stringWithFormat:@"Couldn't sign in: %s", why.c_str()];
            }
        }
    }
#endif
}
