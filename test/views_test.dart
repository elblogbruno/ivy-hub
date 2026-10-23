import 'package:flutter_test/flutter_test.dart';
import 'package:ivy_display/energy.dart';
import 'package:ivy_display/ha.dart';

void main() {
  test('parseViews collects entities from cards, stacks, sections and lists', () {
    final v = parseViews({
      'views': [
        {
          'title': 'Robot',
          'path': 'roborock',
          'cards': [
            {'type': 'picture-entity', 'entity': 'image.map', 'name': 'Mapa'},
            {
              'type': 'vertical-stack',
              'cards': [
                {'type': 'tile', 'entity': 'vacuum.r', 'icon': 'mdi:robot'},
              ],
            },
            {
              'type': 'entities',
              'entities': ['sensor.bat', {'entity': 'select.mode'}, 'sensor.bat'],
            },
            {'type': 'picture-glance', 'camera_image': 'camera.door', 'entities': []},
          ],
        },
        {
          'path': 'sec',
          'sections': [
            {'cards': [{'type': 'tile', 'entity': 'light.a'}]},
          ],
        },
      ],
    });
    expect(v.map((v) => v.title), ['Robot', 'sec']);
    expect(v[0].items.map((i) => i.id), [
      'image.map',
      'vacuum.r',
      'sensor.bat',
      'select.mode',
      'camera.door',
    ]);
    expect(v[0].items.first.name, 'Mapa');
    expect(v[0].items[1].icon, 'mdi:robot');
    expect(v[1].items.single.id, 'light.a');
  });

  test('niceStep gives round gridline steps', () {
    expect(niceStep(16.7), 10); // 0, 10, 20
    expect(niceStep(5.3), 2); // 0, 2, 4, 6
    expect(niceStep(508), 200);
    expect(niceStep(0.9), 0.5);
    expect(niceStep(0), 1);
  });
}
