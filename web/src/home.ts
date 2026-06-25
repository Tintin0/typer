/**
 * Home page entry.
 *
 * FOUNDATION PLACEHOLDER (this wave): imports the shared design system and mounts
 * the shared nav + footer. The next wave replaces the home <main> content (hero
 * caret/ghost-text motif, demo video, how-it-works, model lineup, matrix preview,
 * QoL, offerings ladder, install, FAQ) per docs/marketing/design-system.md §7 —
 * but MUST keep these two lines so the page stays on-system:
 *
 *     import "./styles.css";
 *     mountChrome("home");
 *
 * The previous self-writing typewriter homepage is preserved at
 * src/home-legacy.ts.bak for the next wave to port the hero motif from.
 */
import "./styles.css";
import { mountChrome } from "./shell";

mountChrome("home");
