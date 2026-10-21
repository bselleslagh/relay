"""The nutrition types Relay Hub understands. Keys carry their unit so values are never ambiguous.

Relay uploads HealthKit samples converted to `unit`. Only `writable` nutrients can be queued for
Apple Health writes; the app requests HealthKit write access for exactly those types.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Nutrient:
    key: str
    identifier: str
    unit: str
    title: str
    writable: bool = False


NUTRIENTS: tuple[Nutrient, ...] = (
    Nutrient("energy_kcal", "HKQuantityTypeIdentifierDietaryEnergyConsumed", "kcal", "Energy", writable=True),
    Nutrient("protein_g", "HKQuantityTypeIdentifierDietaryProtein", "g", "Protein", writable=True),
    Nutrient("carbohydrates_g", "HKQuantityTypeIdentifierDietaryCarbohydrates", "g", "Carbohydrates", writable=True),
    Nutrient("fat_g", "HKQuantityTypeIdentifierDietaryFatTotal", "g", "Total fat", writable=True),
    Nutrient("fiber_g", "HKQuantityTypeIdentifierDietaryFiber", "g", "Fiber", writable=True),
    Nutrient("sugar_g", "HKQuantityTypeIdentifierDietarySugar", "g", "Sugar", writable=True),
    Nutrient("saturated_fat_g", "HKQuantityTypeIdentifierDietaryFatSaturated", "g", "Saturated fat"),
    Nutrient("sodium_mg", "HKQuantityTypeIdentifierDietarySodium", "mg", "Sodium"),
    Nutrient("cholesterol_mg", "HKQuantityTypeIdentifierDietaryCholesterol", "mg", "Cholesterol"),
    Nutrient("caffeine_mg", "HKQuantityTypeIdentifierDietaryCaffeine", "mg", "Caffeine"),
    Nutrient("water_ml", "HKQuantityTypeIdentifierDietaryWater", "mL", "Water"),
)

BY_KEY = {nutrient.key: nutrient for nutrient in NUTRIENTS}
BY_IDENTIFIER = {nutrient.identifier: nutrient for nutrient in NUTRIENTS}
WRITABLE_KEYS = tuple(nutrient.key for nutrient in NUTRIENTS if nutrient.writable)
MEAL_TYPES = ("breakfast", "lunch", "dinner", "snack")
