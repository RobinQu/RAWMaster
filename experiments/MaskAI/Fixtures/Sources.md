# Validation fixture provenance

All files are downloaded into the ignored `Fixtures/Downloaded` directory. The hashes below identify the bytes used by this validation, not upstream mutable URLs.

| Fixture | Source | SHA-256 | Intended coverage |
| --- | --- | --- | --- |
| `car.png` | https://huggingface.co/ybelkada/segment-anything/resolve/main/assets/car.png | `c6ae6440e3862dd9768cd9f7098b783ac980629dd7bc1fe69c10b39fca5a84cd` | Subject/background, point and box object prompts |
| `lena.jpg` | https://raw.githubusercontent.com/opencv/opencv/master/samples/data/lena.jpg | `7de7ed51a1594fff247f4cae2301eceacf5313d6011e37b4a4c8733f7bb72c07` | Single person, face and body parts |
| `mountain-lake.jpg` | https://images.unsplash.com/photo-1501785888041-af3ef285b470?auto=format&fit=crop&w=1600&q=90 | `503aa25139ab5cabccdc919c4e76643b97e51cf202643766d9606ad36406c442` | Sky, mountains, water, vegetation and ground |
| `snow.jpg` | https://images.unsplash.com/photo-1483664852095-d6cc6870702d?auto=format&fit=crop&w=1600&q=90 | `bbb3ec36c6a49d873bad48082323791b3e0dbfab154026518f6af987b37c88ec` | Snow compatibility experiment |
| `messi5.jpg` | https://raw.githubusercontent.com/opencv/opencv/master/samples/data/messi5.jpg | `1d570e49654e84c7a943918537bd9e5e1ef82920152e147c834006e235be97c9` | Full-body person and crowded background |

These fixtures validate execution and provide visible inspection samples. They are not a statistically representative photography benchmark and do not establish Adobe-equivalent quality.
