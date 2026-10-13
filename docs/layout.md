# Layout

A layout says where the columns and cards of a space sit around the hub. Every space has one. It is stored in the space's file or the setup's file. See [Spaces and setups](spaces.md).

## Structure

A window is one row: card columns, the hub, then more card columns.

```json
{
  "leading": [
    { "id": "6F1C…", "width": 300, "cards": ["chatwoot-conversations", "commands", "files"] },
    { "id": "B07E…", "width": 440, "cards": ["chatwoot-chat"] }
  ],
  "trailing": [],
  "hidesMainTerminal": true
}
```

| Field | Meaning |
|---|---|
| `leading` | The card columns left of the hub, left to right. |
| `trailing` | The card columns right of the hub, left to right. |
| `hidesMainTerminal` | Optional. When true, the hub leaves out the main terminal. See [The main terminal](#the-main-terminal). |

The hub is not listed. It sits between `leading` and `trailing`, so it always exists exactly once. Putting every column on one side puts the hub at the other edge.

A column has:

| Field | Meaning |
|---|---|
| `id` | A unique ID. |
| `width` | The column's width in points. |
| `cards` | The cards in the column, top to bottom, by card ID. |

When Rune reads a layout, it removes a card listed twice, a column with no cards, and a column whose ID repeats. It raises any width below the minimum to the minimum.

A card ID that Rune does not recognise is kept. It is most likely a custom card whose file is missing. It shows as a placeholder until the file returns or the card is removed.

A layout with no cards at all is valid. The window then shows only the hub.

## Widths

- The space between columns, and around the whole row, is 8 points.
- A card column is at least 160 points wide. A new column starts at 240.
- A card column takes at most 40% of the window's width, whatever its stored width.
- The hub takes all the width the columns leave.

Dragging the gap between a column and its neighbour toward the hub resizes that column. The new width is saved when the drag ends.

## Narrow windows

The hub always stays fully visible. It is guaranteed 480 points, or 40% of the window when the window is too narrow for that.

When the columns would leave the hub less than that, columns collapse one at a time until it fits:

1. The side with more columns gives up its outermost one.
2. If both sides have the same number, the rightmost column collapses first.

A collapsed column is hidden. Its cards stay alive off screen and return when the window is wide enough. There is no control yet for showing a collapsed column in a narrow window.

## Card heights

A card declares how it takes height in its column.

- **Fixed.** The card takes the height of its content.
- **Fill.** The card takes a share of the remaining height. It has a minimum height and a weight.

| Card | Sizing | Minimum | Weight |
|---|---|---|---|
| Commands | Fixed | | |
| Files | Fill | 160 | 1 |
| Changes | Fill | 200 | 2 |
| History | Fill | 120 | 1 |
| Usage | Fixed | | |
| A custom card | Fill unless it says `fixed` | 120 | 1 |

A column's heights are worked out in this order:

1. Fixed cards take their content height, top to bottom. A fixed card is cut short if the column runs out of room.
2. Fill cards share the remaining height by weight.
3. If a fill card's share is below its minimum, it takes the minimum, and the other fill cards share what is left.
4. If the column is too short for every minimum, the fill cards share by weight alone.

Cards in a column are 8 points apart. A column never has a gap between cards. A column holding only fixed cards leaves its spare room at the bottom.

## Moving a card

Drag a card by its header band, the top 40 points of the card. The rest of a card scrolls and selects as usual. A drag starts after 6 points of movement, so a click on a header button still works.

While a card is dragged:

- The card follows the pointer.
- A dashed outline stays where the card was.
- A thin line shows where the card will land.

The pointer's position decides the landing place:

| Pointer is over | The card lands |
|---|---|
| The middle of a column | In that column, above the first card whose middle is below the pointer, or at the bottom |
| Within 28 points of a column's left or right edge | In a new column on that side of it |
| The left half of the hub | In a new column directly left of the hub |
| The right half of the hub | In a new column directly right of the hub |
| The window's left or right margin | In a new outermost column |

No line shows, and nothing happens on release, when the drop would leave the card where it is. That covers a card dropped onto its own place, and a card alone in its column dropped beside that column.

When a card leaves a column empty, the column disappears and the hub takes the space.

Every move saves the layout at once.

A card keeps its state when it moves to another column. A commit message being typed in the Changes card survives the move.

## Removing and adding cards

To remove a card, right-click it and choose **Remove Card**, or use **Remove Card…** in the command palette. Rows inside a card keep their own menus, so right-click the card's header or an empty area.

To add a card, use **Add Card** in any card's right-click menu, or **Show Card…** in the command palette. Both list the built-in cards that are not on screen and every custom card file.

An added card goes to the bottom of the outermost column on its usual side. Commands and Files go left. Every other card goes right. If that side has no column, the card gets a new one.

If every card has been removed, there is no card to right-click. Use the palette.

## The main terminal

Every window has a main terminal. It is the first tab of the hub, and Rune restarts its shell if the shell exits.

A layout can hide it with `hidesMainTerminal`, for a space whose terminals are all opened by its cards. The palette commands are **Hide Main Terminal** and **Show Main Terminal**.

While it is hidden:

- It has no tab, and it never takes the hub or the keyboard.
- It still runs in the background, because other parts of Rune expect a main terminal to exist.
- With no other tab open, the hub shows a short message in place of a terminal.
- ⌘` does nothing.
- ⌘D and ⇧⌘D open a first terminal tab when the hub is empty.
