import 'package:flutter/material.dart';

import 'glossary_screen.dart';

/// The Help hub, reached from the "?" action in the home AppBar: a searchable-ish FAQ (grouped,
/// tap-to-expand) plus an entry into the in-app [GlossaryScreen]. Content lives in [kFaq] below.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Help & FAQ')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('Glossary'),
            subtitle: const Text('Definitions for weaving, knitting & nalbinding terms'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const GlossaryScreen()),
            ),
          ),
          const Divider(height: 1),
          for (final section in kFaq) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text(
                section.title,
                style: text.titleSmall?.copyWith(color: cs.primary),
              ),
            ),
            for (final entry in section.entries)
              ExpansionTile(
                title: Text(entry.question, style: text.bodyLarge),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                expandedAlignment: Alignment.topLeft,
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [Text(entry.answer, style: text.bodyMedium)],
              ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// One FAQ question + answer.
class FaqEntry {
  const FaqEntry(this.question, this.answer);
  final String question;
  final String answer;
}

/// A titled group of FAQ entries.
class FaqSection {
  const FaqSection(this.title, this.entries);
  final String title;
  final List<FaqEntry> entries;
}

/// The FAQ content, grouped by topic. Authored from the actual app behavior.
const List<FaqSection> kFaq = [
  FaqSection('About Ply & privacy', [
    FaqEntry(
      "What is Ply?",
      "Ply is a local-first pattern tool for fiber crafts. You can create, modify, store, and preview patterns right on your phone, with a Flutter app sitting over a fast Rust engine that does the pattern math.",
    ),
    FaqEntry(
      "Which crafts does Ply support?",
      "Three: weaving, knitting, and nalbinding, each on its own tab in the app. Weaving and knitting have full editors with live previews. Nalbinding offers a stitch reference dictionary, a notation playground, and simple saved projects (stitch notation, notes, and photos); a step-by-step recipe model for shaped pieces is planned.",
    ),
    FaqEntry(
      "Do I need an account or an internet connection to use Ply?",
      "No — not for anything Ply does on its own. Ply is local-first with no backend, so creating, editing, and storing patterns runs entirely on your device and works fully offline, with nothing to sign up for. The one exception is the OPTIONAL Ravelry connector (Settings → Ravelry), which is off by default and uses your own Ravelry account to search patterns online.",
    ),
    FaqEntry(
      "Where are my patterns stored?",
      "Your patterns are plain files saved on your device, not in any cloud or proprietary container. Weaving drafts save as standard .wif files (with a small JSON sidecar for app notes), knitting patterns save as .plyknit JSON alongside a preview image, and nalbinding projects save as .plynal files with their photos.",
    ),
    FaqEntry(
      "What platforms does Ply run on?",
      "Ply runs on Android and iOS today. A desktop companion that reuses the same engine is a possible future direction, but it is not built yet.",
    ),
    FaqEntry(
      "Does Ply collect any data or telemetry about me?",
      "No. Because there is no backend and no accounts, Ply has nothing to send anywhere and includes no tracking or telemetry. Your patterns and notes stay private on your device. (The name Ply nods to plied yarn, twisting strands together, and to plying a craft.)",
    ),
    FaqEntry(
      "Does Ply ask for any permissions?",
      "Only one, and only when you use it: the camera, for attaching photos to a project. Choosing an existing picture uses the system photo picker, which needs no permission. Either way the photos are saved on your device and never leave it.",
    ),
    FaqEntry(
      "Can Ply connect to Ravelry?",
      "Optionally, yes. In Settings → Ravelry you can connect with your OWN read-only Ravelry API key (from ravelry.com/pro/developer) to search Ravelry's pattern database. This is the one feature that goes online and uses a Ravelry account; it is off by default and walled off from the rest of the app. Everything else — creating, editing, and storing your patterns — stays fully offline with no account. Your key is stored in your device's keystore and your searches go only to ravelry.com.",
    ),
  ]),
  FaqSection('Weaving', [
    FaqEntry(
      "Can I import my existing WIF files?",
      "Yes. WIF (Weaving Information File) is Ply's native weaving format, so importing is built in: tap Import in the library, pick a .wif file, and the Rust engine parses it and renders a live drawdown. The parser is lenient, it fills in missing sections sensibly and only refuses a file when there is no recognizable draft data at all.",
    ),
    FaqEntry(
      "How do I export or share a draft as a WIF file?",
      "There is no one-tap WIF export yet. Your drafts are saved on your device as real .wif files (with a JSON sidecar and a PNG thumbnail). Export in a draft's library menu makes a .plybackup file, which Ply restores with \"Restore from backup\"; it is not a WIF file for other weaving programs. To give someone a draft they can read and weave from, use Print or share PDF in the editor's overflow menu.",
    ),
    FaqEntry(
      "What does the draft editor screen actually look like?",
      "It is an integrated draft: threading runs across the top, the tie-up sits top-right, the woven-cloth drawdown fills the center, and the treadling (or liftplan) runs down the right side, with warp and weft color bands alongside. Everything shares one cell grid so it stays aligned, and the drawdown recomputes live as you paint edits, with zoom and pan.",
    ),
    FaqEntry(
      "What is the difference between a treadled draft and a liftplan, and can I switch?",
      "A treadled draft uses a tie-up plus a treadling sequence (how a foot loom works), while a liftplan lists the raised shafts directly for each pick (common for table looms and dobby). Ply can convert a treadled draft to a liftplan with one menu action, but that is one-way and lossy: the tie-up and treadling are dropped and cannot be rebuilt, though you can undo right after.",
    ),
    FaqEntry(
      "Can Ply help me figure out my sett and how much yarn to buy?",
      "Yes, the planning calculator has three independent tools: suggest a sett from your wraps-per-inch and structure (plain, twill, or satin), estimate warp yarn from finished length, ends, loom waste and take-up, and estimate weft yarn from picks, woven width and length. These are pure planning aids that read your draft but never change it.",
    ),
    FaqEntry(
      "Can the app generate a weave structure for me?",
      "Yes. The Generate structure sheet offers plain weave, twill, satin, overshot, shadow weave, and double weave. Plain weave, twill, and satin lay down a complete tie-up with a straight or point threading, sized to the warp ends and picks you enter; shadow weave is the Atwater or Powell block weave on 4 or 8 shafts; overshot and double weave are simpler starting points (a two-block overshot with its tabby picks marked, and double weave as two layers, a tube, or double width). Each is committed as a single undoable edit, and the sheet checks your inputs first, for example warning that satin needs at least 5 shafts and a valid counter.",
    ),
    FaqEntry(
      "Will the app tell me if my draft has problems?",
      "Yes. A validation band runs the engine's structural checks live on every edit and appears next to the draft (below the cloth on a phone, in the side panel on a tablet) only when there is something to say, with errors in red, warnings in amber, and notes (advice about a deliberate instruction, such as catching the weft at the selvedge on a double shot) in the accent color. It stays out of the way on a clean draft, and you can tap it to expand a scrollable list with the errors sorted first.",
    ),
  ]),
  FaqSection('Knitting & nalbinding', [
    FaqEntry(
      "How do I make a knitting chart? Can I paint stitches, undo mistakes, and zoom in?",
      "Open the Knitting tab and start a new pattern to get a blank chart. You pick a stitch from the brush row at the bottom, then tap cells to paint them; the toolbar has steppers to add or remove stitches and rows. Undo and redo buttons sit in the top bar, and the More menu has zoom in and zoom out (the chart also scrolls if it is bigger than the screen).",
    ),
    FaqEntry(
      "Can I do colorwork in the knitting chart?",
      "Yes. Below the stitch brushes there is a color palette row where you pick the active color (or choose \"symbol only\" for an uncolored cell), and painting then applies both the stitch and that color. You can add colors with the + swatch and long-press any swatch to edit its RGB, the same palette approach used in the weaving editor.",
    ),
    FaqEntry(
      "How does the cable builder work?",
      "Tap the \"Cable\" chip in the brush row to open the cable builder, where you set the front and back stitch counts (1 to 4 each), pick a right or left cross, and optionally purl the front and/or back strand. On confirm it becomes a new brush (labeled like \"2/2 RC\"), and tapping the chart places the cable anchor and auto-fills the no-stitch cells it spans.",
    ),
    FaqEntry(
      "How do I mark a repeat in a knitting chart?",
      "Draw the repeating stitches once. Switch the top bar's tool button from drawing to selecting, drag across those stitches (on one row or several), and tap Mark repeat. Pick how many times they are worked in all, or To end to repeat them across the rest of the row. The chart outlines each repeat with its count; the written instructions show it as \"[k2, p2] 3 times\" or \"*k2, p2; rep from * to last st, k\"; and stitch counts include every repeat. Select the same stitches and choose Remove repeat to clear one. A first row repeated to the end is counted against the pattern's cast-on; if the pattern has no cast-on set, Ply cannot count that row, and the validation band says so and names the multiple of stitches it needs.",
    ),
    FaqEntry(
      "How do I add short rows, held stitches, or other shaping steps to a knitting pattern?",
      "In the knitting editor, open More > Sections. A section is a named part of the piece, such as Back or Left shoulder, with its steps in order: rows of the chart, knitting or purling across, short rows (wrap and turn, German short rows, or a plain turn when the pattern does not say), casting on, binding off, putting stitches on hold as a named group and returning them to the needle, and written steps in your own words. After every step Ply shows the stitch count: on the needle, still to work in the row, waiting past a short-row turn, on hold, and bound off. It says plainly when a step asks for more stitches than there are, returns stitches that were never put on hold, or leaves short rows unfinished. Ply does not check a written step; give the change in stitch count (0 if none) so it can keep counting. Sections are optional: without them the written instructions follow the chart row by row. Once a pattern has sections, the written instructions and the PDF follow the sections. Sections are counted for flat knitting so far; working in the round, picking up stitches and joining pieces are planned.",
    ),
    FaqEntry(
      "Where do my knitting patterns get saved, and is there written instructions I can copy?",
      "The Save button stores the pattern on your device in your knit library (no account or cloud), and it shows up as a thumbnail tile you can open, rename, or delete. From the More menu, \"Written instructions\" turns the chart into row-by-row text, listed cast-on edge first and aware of right-side/wrong-side rows, and starting with the cast-on (\"Cast on 26 sts.\") when the pattern has one. A pattern with sections is written section by section instead, with the stitch count after each step. Each line is selectable so you can copy the pattern out.",
    ),
    FaqEntry(
      "Is there a gauge and yardage calculator for knitting?",
      "Yes, under More > \"Gauge & yardage\". You can seed a gauge from your yarn's wraps per inch or type your swatch numbers and apply it to the pattern, calculate cast-on stitches from a finished width plus ease (rounded to a stitch-repeat multiple) and set the result as the pattern's cast-on, and get a rough stockinette yardage estimate that also shows a 10% buffer. The yardage figure is an estimate, so plan to buy a little extra.",
    ),
    FaqEntry(
      "Can I set a pattern to be knit flat versus in the round?",
      "Yes, in More > \"Pattern settings\" you switch between Flat and In the round, and for flat work you set whether row 1 is worked from the right or wrong side. That choice drives the written instructions (Row N with RS/WS alternation when flat, versus Round N when in the round). The same sheet holds the cast-on count (blank if the pattern does not say; row 1 is checked against it and the written instructions start with it) and a free-text notes field for yarn, needles, and finishing.",
    ),
    FaqEntry(
      "What can the nalbinding section actually do right now?",
      "You get a curated dictionary of about 12 stitches (each showing its Hansen notation, the a+b thumb-loop alias, alternate names, a generated loop diagram, and a short description) plus a notation playground where you type a Hansen string like \"UO/UOO F1\" and see a live loop diagram and validation. Under My projects you can save a piece you are working on (New project): its name, stitch notation, notes, and photos stay on your device. The loop diagram is a simplified sketch of one stitch, not a picture of finished fabric, and a step-by-step recipe for shaped pieces (starts, increases, shaping) is still planned.",
    ),
  ]),
  FaqSection('Tips & troubleshooting', [
    FaqEntry(
      "Where do all my patterns live, and how do I find the right craft?",
      "The home screen is one library with a tab per craft: Weaving, Knitting, and Nalbinding. Your saved weaves and knits each show up as thumbnails under their tab, and everything is stored as files on your device, so there is no account or cloud sync to worry about.",
    ),
    FaqEntry(
      "How do I back up my patterns, or move them to a new phone?",
      "Open Settings and choose \"Back up library\". Ply saves all your projects (weaving, knitting, and nalbinding, with their photos) into one .plybackup file wherever you choose, such as your Downloads folder or a cloud drive app. To bring them back, use \"Restore from backup\": Ply checks the file, shows you what is new, what you already have, and what differs, and only then adds the projects. Nothing in your library is replaced; a project that differs is added as a copy. The backup can also hold your app settings (theme, colors, and units; ticked by default when you back up), and a restore offers them separately, unticked, so your current settings stay unless you choose them. To share or move just one project, use Export in its menu in the library; the file it saves is restored the same way, with \"Restore from backup\".",
    ),
    FaqEntry(
      "Can I print a pattern or share it as a PDF?",
      "Yes, for every craft, and it works offline. In the weaving editor's overflow menu, the knitting editor's More menu (or the written instructions screen), or a nalbinding project's top bar, choose Print or share PDF. Print sends it to a printer, or saves it as a PDF from the print dialog; Share PDF sends it to another app. The paper follows your units setting: A4 for metric, US Letter for imperial. A weaving PDF has a book draft (threading, tie-up, treadling, and drawdown on one grid, with the tie-up in the corner you choose), the colored drawdown, a key for every mark, and written directions that work without the grids; when the picks are marked pattern and tabby, it also prints the traditional Use tabby shorthand. A knitting PDF has the gauge, the stitch key, the chart, and the written instructions (section by section, with the stitch count after each step, when the pattern has sections); a nalbinding PDF has the notation, the loop diagram, your notes, and your photos (with their location data removed). If a pattern has errors, Ply asks first, and the PDF says so at the top. A PDF is for reading and printing; Ply does not open it again as a pattern.",
    ),
    FaqEntry(
      "What is that colored band in the editor telling me?",
      "That is the inline validation band, and it only appears when there is a real structural issue, so a clean pattern shows nothing. Red means an Error (something that breaks the pattern, like a treadle tying a shaft that does not exist) and amber means a Warning (advisory). Tap the summary to expand the full list, with Errors sorted first.",
    ),
    FaqEntry(
      "Will Ply stop me from saving if my pattern has problems?",
      "No. In the weaving editor, errors prompt you with a confirmation before saving, but you can choose to save anyway, so nothing is ever locked behind a fix; warnings never block saving since they are only advisory. The one hard stop is an empty cloth: you need at least one end and one pick before a weave can be saved. The knitting editor saves without that prompt (problems stay listed in the validation band), and needs at least one row and stitch. In every editor, leaving with unsaved changes asks whether to save or discard them.",
    ),
    FaqEntry(
      "How do undo, redo, and zoom work?",
      "Both the weaving and knitting editors have Undo and Redo buttons in the top bar that walk back and forth through your edit history. Both also zoom from the editor's overflow menu (Zoom in / Zoom out), with weaving snapping through preset zoom steps and knitting nudging a few pixels each tap; in the weaving editor you can also drag to pan the draft. Nalbinding projects are simple forms (name, notation, notes, photos), so they have no undo or zoom.",
    ),
    FaqEntry(
      "Can I change the app's colors or make it easier to read?",
      "Yes, open Settings from the gear icon in the home screen's top bar. You can pick System, Light, or Dark mode, turn on Material You to pull colors from your device wallpaper, or choose an accent color. Changes apply instantly and survive a relaunch, and the app respects your system text size and works with screen readers.",
    ),
    FaqEntry(
      "Where is the glossary, and why can't I do machine knitting export or nalbinding recipes?",
      "The glossary lives right here in Help: tap the Glossary entry at the top of this screen (Help is the question-mark icon in the home screen's top bar). It is a searchable reference covering weaving, knitting, and nalbinding terms. Knitout export for machine knitters is planned but not built yet, so for now knitting is charts plus written instructions only. Nalbinding has the stitch reference, the notation playground, and simple saved projects; the recipe model (worked pieces with shaping steps) is still planned.",
    ),
  ]),
];
