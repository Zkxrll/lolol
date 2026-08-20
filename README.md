## Why this was uploaded

KiciaHook is a paid, obfuscated RIVALS script. Someone deobfuscated it and
posted it on v3rm:
[v3rm.net/threads/kiciahook-leaked.31688](https://v3rm.net/threads/kiciahook-leaked.31688/).
Going by the replies on that thread, nobody could get the output to run. The
dump didn't work and it was barely readable. So our team rebuilt it from that
leak until it did work, and posted it on v3rm for free. We also did it because
we wanted a foundation to build FPS games on.

It went up on our own hub, running through Luarmor on FFA mode, which is
keyless, so anyone could just run it. Luarmor was only there to protect the
integrity of the full source.

Then our API key got blacklisted. No warning. Nobody told us why until we asked,
and the answer was "kicia re-upload".

It wasn't a re-upload. We never hid where it came from, and the leak is the
whole premise of this repo. What matters is whether the thing we shipped was
the same script, and it wasn't. The dump didn't run. We rewrote it to be
readable, put a different UI on it, and added our own features.

One message would have settled it. A Discord message, a reply on the thread,
anything. We'd have taken it down. Nobody asked. They blacklisted the auth, and
when we opened a ticket to find out why, it turned into a threat of legal action
from one of KiciaHook's owners:

**[Screenshot: "Intellectual property theft. Kicia is an LLC if you wanna keep
doing that"](https://prnt.sc/z1rn8RdVg8Ej)**

We take that as a personal attack. We took down the thread, the video and the
script. So now all of it is here instead.

---

## KiciaHook_Deobfuscated.lua

The deobfuscated Kicia source, annotated. Everything here was rebuilt from this,
so you can check the rebuild against it.

---

## Credits

- Original KiciaHook: its authors.
- The dump this was rebuilt from:
  [v3rm.net/threads/kiciahook-leaked.31688](https://v3rm.net/threads/kiciahook-leaked.31688/).
- Reconstruction, additional features, and this release: our team.
