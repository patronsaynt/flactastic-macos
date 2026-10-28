# Privacy Policy for FLACtastic

**Last Updated:** October 2026  
**Version:** 1.1

## 1. Introduction

FLACtastic ("we," "us," "our," or "Application") is a macOS music player and library organizer for lossless audio files. This Privacy Policy explains what information we collect, how we use it, and your rights regarding your data.

FLACtastic respects your privacy. We are designed to minimize data collection and keep your music library under your control on your local machine.

## 2. What Information We Collect

### 2.1 Local Music Files
- **Your music collection:** FLACtastic reads and displays audio files (FLAC, MP3, and other formats) from directories you specify. These files remain stored on your computer and are not transmitted to any servers.
- **Audio metadata:** We locally extract and locally display technical information from your files, including:
  - File format, bitrate, sample rate, and duration
  - Title, artist, album, and year information
  - Album artwork embedded in or associated with files

### 2.2 Application Data Stored Locally
FLACtastic stores the following data on your computer using macOS UserDefaults:
- **Playlist information:** Names, tracks, and order of playlists you create
- **Organizer profiles:** Folder organization settings and grouping preferences
- **Visualizer settings:** Your display preferences and theme selections
- **Application settings:** User preferences, volume levels, and playback settings
- **Listening analytics:** Play counts, listening history, and playback statistics used to display insights on your home screen

All of this data is stored locally on your device and is never sent to external servers or third parties.

### 2.3 Third-Party Service Data

When you choose to use optional features that require external services, we share limited information with those services:

#### Spotify Integration
- **What we share:** When you link your Spotify account, we obtain and store:
  - A refresh token and access token for your Spotify account
  - Your private and collaborative playlist data
  - Playlist track information to enable importing playlists into your FLACtastic library
- **Purpose:** To allow you to import your Spotify playlists and their contents into FLACtastic for local management
- **Storage:** Tokens are stored locally on your device in UserDefaults and never sent to external servers
- **Your control:** You can revoke FLACtastic's access to your Spotify account at any time from your Spotify account settings
- **Spotify's privacy:** Spotify's data collection is governed by Spotify's Privacy Policy, not this document

#### Deezer API
- **What we share:** When displaying artist information, we send:
  - Artist names you browse
  - Search queries you perform
- **Purpose:** To fetch artist profile images and display them in your library
- **No authentication required:** This is a public API call with no personal information
- **Deezer's privacy:** Governed by Deezer's Privacy Policy

#### LrcLib (Lyrics Database)
- **What we share:** When you view song lyrics, we send:
  - Track artist name and title
  - Search queries for matching lyrics
- **Purpose:** To fetch synchronized and plain-text lyrics from the public lrclib.net database
- **No authentication required:** This is a public API call with no personal information
- **LrcLib's privacy:** Governed by LrcLib's Privacy Policy

#### Discord Rich Presence
- **What we share:** When Discord is running and Discord presence is on (it is on by default):
  - Currently playing track information (artist, title, album artwork)
  - Playback state (playing, paused, stopped)
- **Where it goes:** FLACtastic hands this to the Discord app through its local IPC socket. Discord then shows it on your profile, so people who can see your Discord status can see what you're listening to
- **Album artwork:** To show the cover, FLACtastic looks up the album's artist and title with Apple's iTunes Search API (see below)
- **Your control:** This feature only works when Discord is running on your machine and can be turned off in Settings
- **Discord's privacy:** Governed by Discord's Privacy Policy

#### Apple iTunes Search API
- **What we share:** Artist, album and track names, when looking up album artwork for Discord presence and when matching a track to its Apple Music link
- **No authentication required:** This is a public API call with no account or personal information attached
- **Apple's privacy:** Governed by Apple's Privacy Policy

#### Lucida.to Integration
- **What we are:** FLACtastic acts as a frontend to Lucida.to, a music discovery and download service
- **What we share:** When you use FLACtastic to search for and download music:
  - Search queries and requests are sent to Lucida.to
  - Your user interactions and download selections
- **Purpose:** To enable you to discover and import music into your local FLACtastic library
- **Your responsibility:** You agree to only download music you own, have purchased, or otherwise have the legal right to possess. You are responsible for complying with all applicable copyright laws and Lucida.to's terms of service
- **Our policy:** FLACtastic does NOT condone piracy. By using the Lucida.to integration, you agree to use it lawfully and in accordance with Lucida.to's terms
- **Lucida.to's privacy:** Lucida.to's data collection and privacy practices are governed by their own privacy policy

### 2.4 Network Activity
- **Internet connection required:** Some features require network access to fetch artist images, lyrics, and playlist information
- **Local analytics only:** FLACtastic tracks your listening behavior (play counts, skip patterns, frequently played tracks) entirely on your device. This data is **never sent** to any external server or third party
- **No external tracking:** FLACtastic does not collect or send usage analytics, error reports, or behavioral data to any server we control
- **Your network:** All internet requests are made from your computer directly to the services listed above (Spotify, Deezer, LrcLib, Apple's iTunes Search API, Lucida.to)

### 2.5 Local Network Features
- **Library sync:** While the Sync window or Devices tab is open, FLACtastic advertises itself on your local network (Bonjour) so your other devices can find it. A device must be paired with a code shown on screen before it can exchange anything, and paired devices talk over an encrypted connection. Pairing keys are stored in the macOS Keychain and never leave this Mac
- **Casting:** When you play to a network speaker, FLACtastic serves that track and its artwork to the speaker over your local network, at a random address that only the speaker is given and that expires shortly afterwards
- Neither feature sends anything over the internet

## 3. How We Use Your Information

We use the information collected for the following purposes:

1. **Display your music library:** To organize, search, and play your audio files
2. **Manage playlists:** To save, edit, and persist the playlists you create
3. **Enhance the experience:** To fetch artist images, track metadata, and lyrics from public databases
4. **Feature functionality:** To authenticate with Spotify and Discord when you choose to use those features
5. **Application settings:** To remember your preferences, theme selections, and playback settings
6. **Local analytics:** To display listening insights on your home screen (play counts, top tracks, listening statistics)

We do not use your information for:
- Marketing or advertising
- Sending data to external analytics services
- Building user profiles shared with third parties
- Selling or sharing data with third parties (except as required by the integrations you explicitly enable)
- Any purpose outside of improving your local FLACtastic experience

## 4. Data You Control

### 4.1 Your Rights
- **Access:** You can see all data FLACtastic stores about you by viewing your UserDefaults or file system
- **Delete:** You can delete any playlist, organizer profile, or setting at any time
- **Revoke third-party access:** You can disconnect Spotify, Discord, and other services at any time
- **Local control:** All music files and configuration remain on your machine under your control

### 4.2 Exporting and Deleting Data
- Playlists, settings, and analytics are stored in standard macOS formats
- You can export your music library configuration by backing up your UserDefaults directory
- You can reset all listening analytics at any time through the application settings
- Deleting FLACtastic from Applications does not remove its data. To remove everything, also delete `~/Library/Preferences/com.flactastic.app.plist` and `~/Library/Application Support/flactastic`, and remove any "com.flactastic.sync.peerKey" items from Keychain Access

## 5. Data Retention

- **Local data:** FLACtastic retains all application data (playlists, settings) until you delete it
- **Third-party tokens:** Spotify tokens are stored until you revoke access or uninstall the application
- **Cached metadata:** Artist images and lyrics are cached locally to improve performance and may be retained indefinitely

## 6. Security

### 6.1 Local Storage Security
- FLACtastic does not use sandboxing, meaning it has full access to your file system with the permissions you grant
- Your data is protected by macOS file system permissions and your computer's security settings
- Spotify tokens are stored in UserDefaults without encryption; protect your computer from physical access or unauthorized users
- Keys for paired sync devices are stored in the macOS Keychain, limited to this Mac

### 6.2 Network Security
- All communication with external services (Spotify, Deezer, LrcLib) uses HTTPS encryption
- FLACtastic implements standard HTTP timeout settings to prevent hanging requests

### 6.3 What You Can Do
- Keep your macOS system updated with the latest security patches
- Use a strong password on your computer
- Be careful about granting file system permissions
- Revoke Spotify access if you no longer use that feature

## 7. Third-Party Services

FLACtastic integrates with the following services. Their data practices are governed by their own privacy policies:

| Service | Purpose | Privacy Policy |
|---------|---------|---|
| Spotify | Import playlists and playlist contents | https://www.spotify.com/legal/privacy-policy/ |
| Deezer | Artist profile images | https://www.deezer.com/legal/privacy |
| LrcLib | Song lyrics database | https://lrclib.net (public service) |
| Discord | Rich presence for currently playing track | https://discord.com/privacy |
| Apple iTunes Search API | Album artwork and Apple Music links | https://www.apple.com/legal/privacy/ |
| Lucida.to | Music discovery and downloading | https://lucida.to (see their terms) |

We are not responsible for the privacy practices of these third-party services. When using Lucida.to through FLACtastic, you are bound by Lucida.to's privacy policy and terms of service.

## 8. Data Sharing

**We do not share your data** with any party except:
- The third-party services you explicitly connect to (Spotify, Discord, etc.)
- As required by law or legal process
- To prevent fraud or protect the security of the application

We do not sell your data or share it with advertisers, analytics providers, or other third parties.

## 9. Children's Privacy

FLACtastic is not directed toward children under 13. We do not knowingly collect information from children under 13. If you are a parent or guardian and believe we have collected information from a child under 13, please contact us.

## 10. International Users

FLACtastic is designed for use in any country. Because your data is stored locally on your computer and we don't maintain central servers, international data transfer laws don't typically apply. However, when you use third-party integrations (Spotify, Discord, etc.), their international privacy policies may apply.

## 11. Changes to This Policy

We may update this Privacy Policy from time to time. We will notify you of significant changes by:
- Updating the "Last Updated" date at the top of this document
- Posting a notice in the application or on the GitHub repository

Your continued use of FLACtastic after changes become effective constitutes your acceptance of the updated Privacy Policy.

## 12. Contact Us

If you have questions about this Privacy Policy or our privacy practices, please contact us:

- **Email:** ethan@neverangelo.net
- **GitHub:** [github.com/patronsaynt/flactastic](https://github.com/patronsaynt/flactastic)
- **Issues:** Use the GitHub issues page for privacy-related concerns

## 13. Data Controller

FLACtastic is developed by @patronsaynt as an independent project. You are the primary controller of your data, as it is stored on your local machine.

---

**Summary:** FLACtastic keeps your music library and listening history on your computer. All analytics are local—play counts, listening statistics, and playback data never leave your device. We don't send data to external analytics services, build profiles, or sell data. We only share information with services you explicitly enable (Spotify, Lucida.to, Discord, etc.). FLACtastic acts as a frontend to Lucida.to—you are responsible for complying with copyright law and Lucida.to's terms when downloading music. Your privacy is in your hands.
