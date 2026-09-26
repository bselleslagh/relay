"""Rebuild Relay's reviewed catalog from a local Open Wearables 0.9.0 checkout.
Run: python3 scripts/build_catalog.py PATH_TO_OPEN_WEARABLES
The resulting JSON is checked in; this script is not a build-time dependency.
"""
import json,re,pathlib,sys
root=pathlib.Path(sys.argv[1])/'backend'
s=(root/'app/constants/series_types/sdk/metric_types.py').read_text()
ids=dict(re.findall(r'^    (\w+) = "(HKQuantityTypeIdentifier\w+)"',s,re.M))
maps=dict(re.findall(r'SDKMetricType\.(\w+): SeriesType\.(\w+)',s))
units=dict(re.findall(r'SeriesType\.(\w+), "([^"]+)"',(root/'app/schemas/enums/series_types.py').read_text()))
unit_map={'bpm':'count/min','brpm':'count/min','ms':'ms','percent':'%','mg_dl':'mg/dL','mmHg':'mmHg','cm':'cm','kg':'kg','kg_m2':'count','celsius':'degC','ml_kg_min':'ml/kg*min','meters':'m','count':'count','kcal':'kcal','minutes':'min','m_per_s':'m/s','watts':'W','dB':'dBASPL','liters':'L','L/min':'L/min','rpm':'count/min','score':'count'}
# These server mappings have incompatible dimensions or ambiguous units. Do not upload misleading values.
excluded={'BloodAlcoholContent','PhysicalEffort','PeripheralPerfusionIndex','ElectrodermalActivity','AtrialFibrillationBurden','CrossCountrySkiingSpeed','PaddleSportsSpeed','RowingSpeed','NikeFuel','InsulinDelivery'}
rows=[]
for key,identifier in ids.items():
 if key not in maps: continue
 short=identifier.removeprefix('HKQuantityTypeIdentifier')
 if short in excluded: continue
 unit=unit_map[units[maps[key]]]; scale=1
 if short in ['Height','WalkingStepLength']: unit='m'
 if units[maps[key]]=='percent' and short not in ['BodyFatPercentage','WalkingDoubleSupportPercentage','WalkingAsymmetryPercentage','AppleWalkingSteadiness']: scale=100
 if short in ['WorkoutEffortScore','EstimatedWorkoutEffortScore']: unit='appleEffortScore'
 if short=='EnvironmentalSoundReduction': unit='dBASPL'
 group='activity'
 if any(x in short for x in ['Heart','Blood','Oxygen','Respiratory','VitalCapacity','Expiratory','Breathing']): group='vitals'
 elif any(x in short for x in ['Body','Height','Waist','Mass','Temperature']): group='body'
 elif any(x in short for x in ['Audio','Sound','Daylight','UV','WaterTemperature','Underwater']): group='environment'
 elif short in ['NumberOfTimesFallen','InhalerUsage','NumberOfAlcoholicBeverages']: group='other'
 title=re.sub(r'([a-z])([A-Z])',r'\1 \2',short).replace('Apple ','').replace('SDNN','(SDNN)').replace('VO2','VO₂')
 rows.append(dict(id=identifier,title=title,group=group,unit=unit,scale=scale))
pathlib.Path('Relay/Health/Catalog.json').write_text(json.dumps(rows,indent=2)+'\n')
pathlib.Path('docs/COVERAGE.md').write_text('# Health data coverage\n\nSource: Open Wearables 0.9.0, commit ff8527a52ad8a96cd1ebe8c19344295c934ae9dc; live server OpenAPI inspected 26 September 2026.\n\n'+str(len(rows))+' reviewed quantity mappings, plus sleep stages and workouts. Runtime availability depends on iPhone/iOS. All available history is queried without a date cutoff. Apple only returns records the user permits; an empty result does not prove permission was granted.\n\n## Included quantities\n\n| HealthKit type | Upload unit | Scale |\n|---|---|---|\n'+''.join(f'| {r["id"]} | {r["unit"]} | {r["scale"]} |\n' for r in rows)+'\nHeight and walking step length are sent in meters because this server multiplies them by 100. Body fat and walking ratios stay fractions because the server converts them. Oxygen saturation is sent as percent. Running lengths and waist circumference use centimeters; HRV/contact time use milliseconds.\n\n## Not yet transferable through this server contract\n\nNutrition and hydration; reproductive and symptom categories; mindfulness; ECG waveforms; audiograms; clinical records; medication records; activity summaries; workout routes/series; characteristics such as date of birth and blood type. These are not requested or presented as synced.\n\nThe following mapped quantities are excluded because the installed server uses incompatible or ambiguous dimensions: '+', '.join(sorted(excluded))+'.\n\nWorkout summaries, metadata and events are included; routes and high-frequency workout series are not. Uploaded metadata is preserved in the request but the server may not retain it in normalized tables.\n\nHealthKit deletions are recorded in an on-device journal, not deleted from the server: the SDK ingestion API has no deletion contract.\n\n## Receipt semantics\n\nHTTP 202 with a valid receipt confirms acceptance into the server queue, not completed normalization. UI counters mean records sent, not records verified in the database. Background delivery, real HealthKit coverage, and server ingestion require physical-device testing.\n')
print(f'Wrote {len(rows)} reviewed quantity types')
