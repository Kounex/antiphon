# PlatformBadge

The source dot and name that say which service a playlist or track lives on, plus the full-width sign-in capsules used on onboarding.

- Provide: `platform` (`spotify` | `applemusic`) and whether to show the name.
- The dot is 10pt, `spotify` or `applemusic`. Text beside it is `ink`, never the platform color.
- The circle on the sign-in capsule is a placeholder: in the app, place the official logo asset there per each brand's guidelines. This system ships no logos.
- Apple Music sign-in uses `MusicAuthorization.request()` (system prompt, no web view). Spotify uses `ASWebAuthenticationSession` with PKCE.
