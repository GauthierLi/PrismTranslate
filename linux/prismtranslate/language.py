"""Offline language preflight with the original product's confidence rule."""

from functools import lru_cache


@lru_cache(maxsize=1)
def detector():
    from langdetect import DetectorFactory
    from langdetect.detector_factory import PROFILES_DIRECTORY

    factory = DetectorFactory()
    factory.seed = 0
    factory.load_profile(PROFILES_DIRECTORY)
    return factory


def is_already(text, target):
    text = text.strip()
    # Numbers and punctuation must not cause a false skip.
    if len(text) < 2 or sum(character.isalpha() for character in text) < 2:
        return False
    from langdetect.lang_detect_exception import LangDetectException

    recognizer = detector().create()
    recognizer.append(text)
    try:
        values = recognizer.get_probabilities()
    except LangDetectException:
        return False
    if not values or values[0].prob < .65:
        return False
    detected = values[0].lang
    return detected in ("zh-cn", "zh-tw") if target in ("zh-Hans", "zh-Hant") else detected == target
