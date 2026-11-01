// Sources and layers of the public map (mapbox_controller.js): problems, boulders,
// circuits, POIs, areas, and the mapping requests shown in contribute mode.
// The grade palette comes from ProblemsHelper#grade_colors_json.
// MapLibre ["match", ["get","grade"], grades, color, ..., fallback]
export function gradeColorExpression(palette) {
  palette = palette || {}
  const pairs = palette.colors || []
  if (!pairs.length) return palette.unknown || "#878A8D"
  return ["match", ["get", "grade"],
    ...pairs.flatMap(([color, grades]) => [grades, color]),
    palette.unknown || "#878A8D"]
}

// Circuit-number labels sit on the grade-coloured dot, so they take the same
// dark-on-pale treatment as ProblemsHelper#grade_text_color.
export function gradeTextColorExpression(palette) {
  palette = palette || {}
  const pale = (palette.colors || [])
    .filter(([color]) => color.toUpperCase() === "#FFFFFF")
    .flatMap(([, grades]) => grades)
  if (!pale.length) return "#fff"
  return ["match", ["get", "grade"], pale, "#333", "#fff"]
}

// Pale dots get an outline so they stay visible against the base map.
export function gradeStrokeExpression(palette) {
  palette = palette || {}
  const pale = (palette.colors || [])
    .filter(([color]) => color.toUpperCase() === "#FFFFFF")
    .flatMap(([, grades]) => grades)
  if (!pale.length) return "rgba(0,0,0,0)"
  return ["match", ["get", "grade"], pale, palette.outline || "#888", "rgba(0,0,0,0)"]
}

// options: { mapDataSource, areaLabelsSource, contributeSource, contribute, gradeColors }
export function addMapLayers(map, options) {
  const palette = options.gradeColors
  if (options.mapDataSource) {
    map.addSource('problems', {
      type: 'geojson',
      data: options.mapDataSource,
      promoteId: "id"
    });
  }

  // BOULDER OUTLINES (added before problems so circles appear on top)
  if (options.mapDataSource) {
    map.addLayer({
      'id': 'boulders',
      'type': 'fill',
      'source': 'problems',
      'minzoom': 16,
      'paint': {
        'fill-color': '#888',
        'fill-opacity': 1,
      },
      filter: ['match', ['geometry-type'], ['Polygon'], true, false],
    });

    map.addLayer({
      'id': 'boulders-outline',
      'type': 'line',
      'source': 'problems',
      'minzoom': 16,
      'paint': {
        'line-color': '#555',
        'line-width': 1.5,
      },
      filter: ['match', ['geometry-type'], ['Polygon'], true, false],
    });
  }

  if(true) {
  map.addLayer({
    'id': 'problems',
    'type': 'circle',
    'source': 'problems',
    'minzoom': 15,
    'layout': {
      'visibility': 'visible',
      'circle-sort-key': 
        [
          "case",
          ["has", "circuitId"],
          2,
          1
        ]
    },
    'paint': {
      'circle-radius': 
        [
          "interpolate",
          ["linear"],
          ["zoom"],
          15,
          2,
          18,
          4,
          22,
          [
            "case",
            ["has", "circuitNumber"],
            16,
            10
          ]
        ]
      ,
      'circle-color': gradeColorExpression(palette),
      'circle-stroke-width': 1,
      'circle-stroke-color': gradeStrokeExpression(palette),
      'circle-opacity': 
      [
        "interpolate",
        ["linear"],
        ["zoom"],
        14.5,
        0,
        15,
        1
      ]
    },
    filter: [
      "match",
        ["geometry-type"],
        ["Point"],
        true,
        false
    ],
  });

  map.addLayer({
    'id': 'problems-texts',
    'type': 'symbol',
    'source': 'problems',
    'minzoom': 19,
    'layout': {
      'visibility': 'visible',
      'text-allow-overlap': true,
      // OpenFreeMap only serves Noto Sans glyphs; the MapLibre default
      // ("Open Sans Regular,Arial Unicode MS Regular") 404s and renders nothing.
      'text-font': ['Noto Sans Regular'],
      'text-field': [
        "to-string",
        ["get", "circuitNumber"]
      ],
      'text-size': [
        "interpolate",
        ["linear"],
        ["zoom"],
        19,
        10,
        22,
        20
      ],
    },
    'paint': {
      'text-color': gradeTextColorExpression(palette),
    },
    filter: [
      "match",
        ["geometry-type"],
        ["Point"],
        true,
        false
    ],
  });
  } // end problems block

  // AREA LABELS
  if (!!options.areaLabelsSource) {
    map.addSource('areas', {
      type: 'geojson',
      data: options.areaLabelsSource,
    });

    map.addLayer({
      'id': 'areas-circles',
      'type': 'circle',
      'source': 'areas',
      'minzoom': 8,
      'maxzoom': 16,
      'paint': {
        'circle-color': '#6F767A',
        'circle-opacity': 0.25,
        'circle-stroke-color': '#6F767A',
        'circle-stroke-width': 1,
        'circle-stroke-opacity': 0.5,
        'circle-radius': [
          'interpolate', ['linear'], ['zoom'],
          8,  ['interpolate', ['linear'], ['get', 'problemCount'], 0, 4,  50, 10, 250, 18],
          12, ['interpolate', ['linear'], ['get', 'problemCount'], 0, 7,  50, 18, 250, 32],
        ],
      },
    });

    map.addLayer({
      'id': 'areas',
      'type': 'symbol',
      'source': 'areas',
      'minzoom': 8,
      'maxzoom': 16,
      'filter': [
        'any',
        ['>=', ['zoom'], 10],
        ['==', ['get', 'priority'], 1],
      ],
      'layout': {
        'symbol-sort-key': ['get', 'priority'],
        'text-field': ['get', 'name'],
        'text-size': [
          'interpolate', ['linear'], ['zoom'],
          10, 12,
          14, 16,
        ],
        'text-font': ['Noto Sans Bold'],
        'text-anchor': 'center',
      },
      'paint': {
        'text-color': '#333',
        'text-halo-color': '#fff',
        'text-halo-width': 1.5,
      },
    });
  }

  // CONTRIBUTE LAYERS

  if(options.contribute) {

    map.addSource('contribute', {
      type: 'geojson',
      data: options.contributeSource,
    });

    map.addLayer({
    'id': 'contribute-problems',
    'type': 'circle',
    'source': 'contribute',
    // 'source-layer': 'problems-ayes3a',
    // 'minzoom': 12,
    'layout': {
      'visibility': 'visible',
      'circle-sort-key': 
        [
          "case",
          ["has", "circuitId"],
          2,
          1
        ]
    },
    'paint': {
      'circle-radius': 
        [
          "interpolate",
          ["linear"],
          ["zoom"],
          12,
          6,
          17,
          20,
          18,
          25,
          19,
          50,
          20,
          50,
          21,
          50,
          22,
          20,
        ]
      ,
      'circle-color': "#FFCC02",
      'circle-opacity': 0.25,
      'circle-stroke-width': 2,
      'circle-stroke-color': 'white'
    },
    filter: [
      "match",
        ["geometry-type"],
        ["Point"],
        true,
        false
    ],
    });

    map.addLayer({
    'id': 'contribute-problems-texts',
    'type': 'symbol',
    'source': 'contribute',
    // 'source-layer': 'problems-ayes3a',
    'minzoom': 16,
    'layout': {
      'visibility': 'visible',
      'text-allow-overlap': true,
      'text-font': ['Noto Sans Regular'],
      'text-field': [
        "to-string",
        ["get", "name"]
      ],
      'text-size': [
        "interpolate",
        ["linear"],
        ["zoom"],
        19,
        10,
        22,
        20
      ],
    },
    'paint': {
      'text-color': "#333",
      'text-halo-color': "hsl(0, 0%, 100%)",
      'text-halo-width': 1,
    },
    filter: [
      "match",
        ["geometry-type"],
        ["Point"],
        true,
        false
    ],
    });
  }

}
