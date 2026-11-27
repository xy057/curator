/// Attacca's own version (docs/daw-link.md ▸ Its version): a whole number apart from Curator's,
/// raised by one whenever the plug-in (daw_link/) changes, and only then. A Curator update that
/// leaves it alone leaves every Attacca installed as good as the one it bundles; one that raises
/// it has each older Attacca told it is outdated. (It began at 630, Curator's build then: every
/// Attacca from before had Curator's build for its version, all lower.) The Makefile reads it
/// from here for the plug-in, and `make versions` fails when daw_link/ changed since
/// `make attacca-seal` (which goes with raising it).
const attaccaVersion = 632;
