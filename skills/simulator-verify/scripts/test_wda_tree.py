"""wda_tree.elements: rects inside a lock-screen Live Activity card come back in screen points.

The fixture is the shape of a real tree read on 2026-11-23 (iPhone 17 Pro simulator,
iOS 27): the card's host view at [19,395,364,156], the widget's own root restarting at
[0,0,374,160], its Pause pill at [20,104,334,45]. The screenshot taken with it put the
pill at about x 39-362, y 496-540 - the expected rect below.

  python3 -m unittest test_wda_tree
"""
import unittest

from wda_tree import elements


def node(type_, rect, label=None, name=None, children=()):
    n = {"type": type_, "isVisible": "1", "children": list(children),
         "rect": dict(zip(("x", "y", "width", "height"), rect))}
    if label:
        n["label"] = label
    if name:
        n["name"] = name
    return n


def lock_screen(card_y=395):
    widget = node("Other", [0, 0, 374, 160], children=[
        node("StaticText", [20, 11, 181, 22], label="Demo Workout"),
        node("Other", [0, 0, 374, 80], children=[node("StaticText", [20, 58, 163, 37], label="0:24")]),
        node("Button", [20, 104, 334, 45], label="Pause"),
    ])
    card = node("Other", [19, card_y, 364, 156], name="activity-content-view",
                children=[node("Other", [19, card_y, 364, 156], children=[widget])])
    return node("Application", [0, 0, 402, 874], children=[
        node("Other", [0, 0, 402, 874], children=[
            node("StaticText", [100, 120, 200, 40], label="14:40"),
            card,
            node("Button", [33, 596, 164, 44], label="Allow"),
        ]),
        # a remote-looking [0,0] child outside any card stays as it is
        node("Other", [50, 60, 100, 100], children=[node("Button", [0, 0, 40, 40], label="Corner")]),
    ])


def rect_of(els, label):
    return next(e["rect"] for e in els if e.get("label") == label)


class CardRects(unittest.TestCase):
    def test_pill_maps_onto_the_screen(self):
        self.assertEqual(rect_of(elements(lock_screen(), False), "Pause"), [38, 496, 325, 44])

    def test_follows_the_card_when_it_moves(self):
        # the card moved to y 581 once the prompt under it was answered
        self.assertEqual(rect_of(elements(lock_screen(card_y=581), False), "Pause"), [38, 682, 325, 44])

    def test_a_local_origin_inside_the_widget_does_not_rescale(self):
        # the [0,0,374,80] block is the widget's top half, not a second remote view
        self.assertEqual(rect_of(elements(lock_screen(), False), "0:24"), [38, 452, 159, 36])

    def test_nodes_outside_the_card_are_untouched(self):
        els = elements(lock_screen(), False)
        self.assertEqual(rect_of(els, "14:40"), [100, 120, 200, 40])
        self.assertEqual(rect_of(els, "Allow"), [33, 596, 164, 44])
        self.assertEqual(rect_of(els, "Corner"), [0, 0, 40, 40])

    def test_card_host_itself_is_untouched(self):
        els = elements(lock_screen(), True)
        self.assertIn([19, 395, 364, 156], [e["rect"] for e in els])

    def test_node_without_rect_does_not_crash(self):
        tree = lock_screen()
        tree["children"][0]["children"][1]["children"][0].pop("rect")
        elements(tree, True)


if __name__ == "__main__":
    unittest.main()
