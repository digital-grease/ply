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
            subtitle: const Text('Definitions for weaving, knitting, nalbinding & tablet weaving terms'),
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
      "Four: weaving, knitting, nalbinding, and tablet weaving (also called card weaving), each on its own tab in the app. Weaving, knitting and tablet weaving have full editors with live previews. Nalbinding offers a stitch reference dictionary, a notation playground, and saved projects (stitch notation, notes, photos, and an optional step-by-step recipe you can follow).",
    ),
    FaqEntry(
      "Do I need an account or an internet connection to use Ply?",
      "No — not for anything Ply does on its own. Ply is local-first with no backend, so creating, editing, and storing patterns runs entirely on your device and works fully offline, with nothing to sign up for. The one exception is the OPTIONAL Ravelry connector (Settings → Ravelry), which is off by default and uses your own Ravelry account to search patterns online.",
    ),
    FaqEntry(
      "Where are my patterns stored?",
      "Your patterns are plain files saved on your device, not in any cloud or proprietary container. Weaving drafts save as standard .wif files (with a small JSON sidecar for app notes), knitting patterns save as .plyknit JSON alongside a preview image, nalbinding projects save as .plynal files with their photos, and tablet weaving bands save as .plytab files.",
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
      "Can I read or change a draft's notes after saving it?",
      "Yes. The notes you add when you first save a draft can be read and changed at any time: in the library, open the draft's menu (the three dots on its tile, or press and hold the tile) and choose Notes, or choose Notes in the editor's overflow menu once the draft is saved. A draft's notes can be up to 10,000 characters, and the box shows how many you have. They are Ply's own: kept with the draft on your device and in its backups and exports, but not printed and not part of the WIF file (a PDF's Notes section shows the notes written inside the WIF file itself, by the program that made it). Changing them never changes the draft or marks it edited. Cancel leaves them as they were, and Back asks before throwing away a change. A draft saved by an earlier version of Ply can have longer notes: they open in full to read, and you choose what to do. Save them as a text file to keep them all, then keep the first 10,000 characters (shown to you first) or clear them (Ply asks first); notes not much over the limit can also be shortened by hand. Nothing changes until you choose. Notes over about 1 MB stop a backup until you shorten them, and the backup says which draft it is.",
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
      "Can Ply tell me whether a draft fits my loom?",
      "Yes. In Settings, under My looms, describe the looms you weave on: the loom type (jack, counterbalance, countermarch, table or dobby), how many shafts and treadles it has, how many treadles you press at once, its weaving width and your reeds. Every field is optional, so leave out what you do not know. Then choose Loom for this draft in the weaving editor's overflow menu, pick the loom, and enter the sett if the file does not give one. A loom group appears under the draft, apart from the structural checks, such as \"On Floor loom: not feasible, needs 8 shafts, has 4\". Tap it to see every check: the shafts, the treadles (a table loom or dobby works from the liftplan instead), how many treadles a pick presses at once, whether the tie-up suits the way your loom moves its shafts, unbalanced sheds on a counterbalance loom, the width in the reed (a double-width cloth is checked folded, as it sits on the loom), and which reed and sleying give the sett. A check that needs something you have not recorded says so instead of guessing. The loom check never stops you saving, and the loom you choose is saved with the draft, never in its WIF file.",
    ),
    FaqEntry(
      "How do I record my yarns and swatches, and use a swatch in a calculator?",
      "Tap the box icon at the top of the home screen to open Materials and swatches. A material is a yarn you describe with as much or as little as you know: its fibers, weight category, structure, the length per mass from its ball band (or weighed yourself), wraps per inch, color, dye lot and how much you have. A swatch records what you measured: the craft and technique, the yarns and tools (for weaving, the sett and the width in the reed), the width, length and counts before and after finishing (and on the loom for weaving), how you finished it and measured it, its weight, and photos. When you add a photo, to a swatch or to a nalbinding project, Ply removes its location, camera and time details if it is a JPEG or PNG, and keeps which way up it is; a WebP or HEIC photo is kept as it is, details and all. Photos stay on your device unless you make a backup. Every number keeps its unit and says whether you measured it or entered it from somewhere else, and Ply shows what it works out from them, such as the gauge per 10 cm, how much the swatch grew or shrank, or the take-up and draw-in of a woven sample, without ever saving those in place of your measurements. In any editor, Materials and swatches... (in the menu, or the box icon for nalbinding) links the project to yarns and swatches, and one swatch can serve many projects. Then, in Gauge & yardage, the Calculators tab or the weaving planning calculator, choose Use a swatch: the estimate lists every input with where it came from, such as \"20 sts per 10 cm, measured after finishing, swatch Grey wool 2026-11-10\", and marks Ply's defaults as assumed. With no materials or swatches, nothing changes.",
    ),
    FaqEntry(
      "How do I plan a warp from the size I want the cloth to be?",
      "In the weaving editor, open More > Warp and weft plan. Enter the finished width and length of one item after washing, how many items go on the warp, and any hems, fringe or sampling length, and choose the structure. Choose a swatch you wove and finished like the project, and the warp and weft yarns. Ply then works back to the warp ends (rounded to your threading repeat, plus any extra ends such as floating selvedges), the width in the reed, how to sley the reed of the loom chosen in Loom for this draft, the warp length to wind, the picks and the weft, and how much yarn that is against what you have on hand. Every assumption says where it came from: measured from the swatch, entered by you, or a Ply default, which is a rule of thumb for the structure (such as 10% take-up for plain weave) and only an estimate. Each says what it is a share of: take-up of the length on the loom, shrinkage of the size off the loom, draw-in of the width in the reed. Ply plans by dividing by what is lost, which needs a little more than adding the percentage. You can change any one assumption, such as the take-up, and change it back with Use the swatch or Use Ply's estimate; your own value never changes the swatch or the yarn. Open a figure to see how it was worked out. The plan is saved with the draft, and Remove this plan takes it out.",
    ),
    FaqEntry(
      "Will the app tell me if my draft has problems?",
      "Yes. A validation band runs the engine's structural checks live on every edit and appears next to the draft (below the cloth on a phone, in the side panel on a tablet) only when there is something to say, with errors in red, warnings in amber, and notes (advice about a deliberate instruction, such as catching the weft at the selvedge on a double shot) in the accent color. It stays out of the way on a clean draft, and you can tap it to expand a scrollable list with the errors sorted first.",
    ),
  ]),
  FaqSection('Tablet weaving', [
    FaqEntry(
      "How do I draft a tablet weaving band?",
      "Open the Tablet weaving tab in the library (tablet weaving is also called card weaving). Each band is saved on your device as a .plytab file. The editor has four parts. Cards: give each hole of each card (A, B, C and D) a thread from the palette, or leave it empty; choose S or Z threading; choose where the card starts from two presets, \"A at the near top\" (Ply's home position, listed first and the default for a new band) or \"printed face to the right, D at the near top\" (the way many commercial cards are set); and put cards into packs. Turning: a letter for each card on each pick, F for forward, B for backward, I for idle, or ? for something Ply does not model, such as a half turn, kept with the pattern's own words; add a flip or a twist release before a pick; and work a segment of picks several times. Band: the band chart, drawn with pick 1 at the bottom and the newest pick at the top, as the band grows away from you (unlike Ply's shaft-weaving drafts, which put pick 1 at the top); the top face with card 1 at the left, and the back, as seen with the band turned over, with card 1 at the right; and a step-by-step player that shows each card's position and twist at every pick. Checks: warnings such as long floats and high twist, the things Ply does not model, and errors; tap one to go to it. The rules Ply uses to work out the faces and the twist await a tablet weaver's review, so until then treat what Ply shows as a guide. You can print a band or share it as a PDF with the setup, the turning chart, the band chart, the written instructions and the checks. Ply does not read or write WIF or other programs' files for tablet weaving.",
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
      "In the knitting editor, open More > Sections. A section is a named part of the piece, such as Back or Left shoulder, with its steps in order: rows of the chart, knitting or purling across, short rows (wrap and turn, German short rows, or a plain turn when the pattern does not say), casting on, binding off, putting stitches on hold as a named group and returning them to the needle, and written steps in your own words. After every step Ply shows the stitch count: on the needle, still to work in the row, waiting past a short-row turn, on hold, and bound off. It says plainly when a step asks for more stitches than there are, returns stitches that were never put on hold, or leaves short rows unfinished. Ply does not check a written step; give the change in stitch count (0 if none) so it can keep counting. Sections are optional: without them the written instructions follow the chart row by row. Once a pattern has sections, the written instructions and the PDF follow the sections. Sections are counted for flat knitting and for knitting in the round; a section can also say which it is, from its menu (Flat or in the round). A garment made in several pieces, such as a body and two sleeves, can name its pieces; each section then works one of them (see the answer on garments in several pieces).",
    ),
    FaqEntry(
      "Can Ply count a sock heel, a gusset and a toe?",
      "Yes. In a pattern worked in the round, Sections has steps for each part of a sock: Rows or rounds (such as 50 rounds of the leg), Needle groups (name the stitches, such as 32 sole and 32 instep, and every count after that gives each group), Work part of the round flat (a heel flap over the sole stitches, slipping the first stitch of every row, while the instep rests), short rows that turn at the gap with a decrease before the turn (a heel turn), Pick up and knit (along the left or right side of the heel flap, onto the sole), Join in the round (to go back to rounds), Move the start of the round (after the gusset pick-up, knit to the center of the heel and start the rounds there), Shaping (such as decreasing 2 sole stitches every other round until 64 remain, or 4 stitches every round on the toe), and Graft or close (Kitchener stitch, or a three-needle bind-off). A short-row heel worked in the round uses Work part of the round flat, short rows to the double stitch or the wrapped stitch and back out past the gap, and Join in the round. Ply refuses a step that cannot be worked, such as a shaping that cannot reach its stitch count in whole repeats, and says why. Along a heel flap it says how many slipped edge stitches each side has, but you choose how many to pick up: Ply never guesses.",
    ),
    FaqEntry(
      "Can Ply follow a garment made in several pieces, such as a sweater or a mitten with its thumb?",
      "Yes. On the Sections screen, Add a piece names a part knitted on its own needle, such as a sleeve or a thumb; the first piece, called Main piece until you rename it, keeps the sections you already have and is the one the cast-on is for. Each section works one piece (choose it from the section's menu, Piece), and Ply keeps a count for every piece: while one is worked, the others are listed as set aside with their stitches. To bring pieces together, use Join a piece or held stitches: it knits another piece's stitches, or stitches on hold, into the row or round where the work is, with the right side facing, such as each sleeve knitted onto the body for a yoke in place of the underarm stitches put on hold. To split a piece, put each part's stitches on hold, as a raglan yoke does with its sleeves, and let each new piece take them up in its own sections: a join that knits them, with Pick up and knit for the stitches around them and Join in the round, makes a sleeve or a thumb. To close two groups on hold against each other, such as the underarm stitches of a body and a sleeve, use Graft or close with Close two groups on hold. Ply refuses a join that cannot be worked, such as a piece partway through a row, one already joined, or stitches already taken off the holder; a piece joined to another cannot be worked again (start a new piece instead); and the Pieces card says how each piece ends. The written instructions and the PDF name each section's piece in its heading.",
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
      "You get a curated dictionary of about 12 stitches (each showing its Hansen notation, the a+b thumb-loop alias, alternate names, a generated loop diagram, and a short description) plus a notation playground where you type a Hansen string like \"UO/UOO F1\" and see a live loop diagram and validation. Under My projects you can save a piece you are working on (New project): its name, stitch notation, notes, and photos stay on your device. The loop diagram is a simplified sketch of one stitch, not a picture of finished fabric. A project can also hold a recipe: the piece as steps in working order, which you can follow one at a time.",
    ),
    FaqEntry(
      "How do I write a nalbinding recipe and follow it?",
      "Open a nalbinding project and choose Add a recipe (it is optional; your notes stay as they are). Add the steps in working order: a start (a foundation chain joined into a ring or left open, a centre start, or loops picked up around an earlier opening, such as a thumb), the body (rounds in a spiral or joined, or rows), the shaping (increases, decreases, short rows, an opening such as a thumb opening, a join), and a finish (draw the last loops together, or taper at an open edge). A mitten has two parts: the hand, then the thumb. Each step can use the project's stitch or its own Hansen notation (a denser cuff, say), say how far it goes (a number of rounds, until a stitch count, or until it reaches or measures something), and hold notes and a warning for whoever follows it. For anything the kinds cannot say, use Free text: Ply keeps your words and does not check them. Drag a step or use its menu to move, duplicate or delete it. Ply checks the order, the numbers and each stitch's notation, and counts the stitches from your own numbers when they are stated; it does not simulate the fabric, so whether the piece fits or lies flat is for you to judge. Choose Follow to work through the recipe one step at a time and tick each step done; ticks on a saved project are kept at once.",
    ),
  ]),
  FaqSection('Tips & troubleshooting', [
    FaqEntry(
      "Where do all my patterns live, and how do I find the right craft?",
      "The home screen is one library with a tab per craft: Weaving, Knitting, Nalbinding, and Tablet weaving. Your saved weaves, knits and bands each show up as thumbnails under their tab, and everything is stored as files on your device, so there is no account or cloud sync to worry about.",
    ),
    FaqEntry(
      "How do I keep my place while I weave or knit?",
      "Save the draft or pattern, then choose Weave pick by pick (the weaving editor's overflow menu) or Knit row by row (the knitting editor's More menu). The screen shows the pick you are on and what to press or lift for it (which treadles, and which shafts rise; on a sinking shed, which go down and which stay up), the weft color and any shuttle or double shot, or the chart row or section step you are on with what to knit and the stitch count after it. Inside a step that works several rows, such as a run of rows or a shaping step, it counts the rows and says which are shaping rows. Tap Next when the pick or row is done and Previous to correct a mistap. Go to sets your place by hand, and Undo puts back your last change of place, even after closing the app. A draft or chart can be worked again and again; the screen counts the times through. Your place is saved at once on your device, apart from the pattern itself, so it never changes the pattern or marks it edited, and when you come back, even after restarting the phone and with no connection, you are where you stopped. Add a note at any place (\"started the second ball\"), see every note under Notes, and see what you worked and when under Log. If the pattern was changed since you saved your place (picks or rows added or removed before it), Ply shows your place for you to check and never moves it on its own; if your place is past the new end, it is shown at the last pick or row. Clear my place removes your place, log and notes for that project; deleting the project removes them too. A backup or an export carries your place, log and notes with the project. A backup's place is used only for a project restored as new or as a copy, which brings its place with it; a project you already have keeps your place as it is (or stays without one). Nalbinding recipes keep their own Done ticks in the follow view.",
    ),
    FaqEntry(
      "How do I back up my patterns, or move them to a new phone?",
      "Open Settings and choose \"Back up library\". Ply saves all your projects (weaving, knitting, nalbinding, and tablet weaving, with their photos) into one .plybackup file wherever you choose, such as your Downloads folder or a cloud drive app. To bring them back, use \"Restore from backup\": Ply checks the file, shows you what is new, what you already have, and what differs, and only then adds the projects. Nothing in your library is replaced; a project that differs is added as a copy. The backup also holds your looms from My looms: a restore adds the looms you do not have, and offers a loom that differs from yours as a copy. It holds your materials and swatches with the swatches' photos the same way, and a project restored with them links the restored copies. Each project's place, log and notes from Weave pick by pick or Knit row by row go with it: a project restored as new or as a copy brings them, and a project you already have keeps your own. The backup can also hold your app settings (theme, colors, and units; ticked by default when you back up), and a restore offers them separately, unticked, so your current settings stay unless you choose them. To share or move just one project, use Export in its menu in the library; the file it saves is restored the same way, with \"Restore from backup\". If a weaving draft saved by an earlier version of Ply has notes too long to back up, the backup names the draft: shorten them with Notes in its menu in the library, and back up again.",
    ),
    FaqEntry(
      "Can I print a pattern or share it as a PDF?",
      "Yes, for every craft, and it works offline. In the weaving editor's overflow menu, the knitting editor's More menu (or the written instructions screen), or a nalbinding project's top bar, choose Print or share PDF. Print sends it to a printer, or saves it as a PDF from the print dialog; Share PDF sends it to another app. The paper follows your units setting: A4 for metric, US Letter for imperial. A weaving PDF has a book draft (threading, tie-up, treadling, and drawdown on one grid, with the tie-up in the corner you choose), the colored drawdown, a key for every mark, and written directions that work without the grids; when the picks are marked pattern and tabby, it also prints the traditional Use tabby shorthand. A knitting PDF has the gauge, the stitch key, the chart, and the written instructions (section by section, with the stitch count after each step, when the pattern has sections); a nalbinding PDF has the notation, the loop diagram, your notes, the recipe step by step (when the project has one), and your photos (with their location data removed). Before it makes the PDF, Ply checks whether the pattern is ready to make or share (see the next question). A PDF is for reading and printing; Ply does not open it again as a pattern.",
    ),
    FaqEntry(
      "What does \"ready to make or share\" mean, and what is a draft copy?",
      "When you print or share a pattern, Ply first checks everything the PDF depends on: for a weaving draft its structure, the loom chosen for it and its warp and weft plan; for knitting the chart and the sections; for nalbinding the notation and the recipe. A pattern with no errors is ready to make or share. If Ply found warnings, or things it could not check (a step in the pattern's own words, a loom setting your loom profile does not record), it lists them once and you go ahead with Acknowledge and print (or share). If the pattern has errors it is not ready: Go back closes the question without making anything, or choose Print a draft copy (or Share a draft copy). Every page of a draft copy says \"Draft copy, not ready to make or share\" with the number of errors, its first page lists them, and its file name ends in \"(draft copy)\". A loom that does not fit the draft never makes it a draft copy: the draft may be right for another loom, so it is a warning. Saving is never checked this way, and neither are a project export or a backup: they keep your work exactly as it is, problems and all. Preparing a large pattern's PDF can take a moment; Cancel stops it and makes nothing.",
    ),
    FaqEntry(
      "What is that colored band in the editor telling me?",
      "That is the inline validation band, and it only appears when there is a real structural issue, so a clean pattern shows nothing. Red means an Error (something that breaks the pattern, like a treadle tying a shaft that does not exist) and amber means a Warning (advisory). Tap the summary to expand the full list, with Errors sorted first. Each finding says where it is (a pick and treadle, an end and shaft, a chart row and column, a section's step), and Show goes there: the weaving editor scrolls to the place and outlines it, the knitting editor selects the row or stitch in the chart and scrolls to it, and a section's problem opens the Sections screen at its step. Knitting chart columns are named as the chart numbers them, stitch 1 at the right edge; where a row is worked from the other side, the place also says which stitch it is as the row is worked.",
    ),
    FaqEntry(
      "Will Ply stop me from saving if my pattern has problems?",
      "No. No editor asks about problems before saving, whatever errors or warnings a pattern has, so nothing is ever locked behind a fix. The problems stay listed where you saw them: the validation band in the weaving and knitting editors, the Checks tab of a tablet weaving band, and the list under the notation in a nalbinding project. The only hard stops are for an empty pattern: a weave needs at least one end and one pick, and a knitting pattern needs some rows and stitches in its chart, or a section. A first save asks for a name, and the weaving editor asks once before rewriting an imported WIF file it has to change. In every editor, leaving with unsaved changes asks whether to save or discard them. Whether a pattern is ready to make or share is checked only when you print or share it, never when you save.",
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
      "Where is the glossary, and why can't I do machine knitting export?",
      "The glossary lives right here in Help: tap the Glossary entry at the top of this screen (Help is the question-mark icon in the home screen's top bar). It is a searchable reference covering weaving, knitting, nalbinding, and tablet weaving terms. Knitout export for machine knitters is planned but not built yet, so for now knitting is charts plus written instructions only. Nalbinding has the stitch reference, the notation playground, and saved projects, and a project can hold a recipe (the piece as steps in working order, with its shaping) that you can follow one step at a time.",
    ),
  ]),
];
