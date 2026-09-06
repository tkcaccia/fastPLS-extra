from pathlib import Path
from PIL import Image, ImageOps, ImageDraw
base = Path(__file__).resolve().parents[1]/'manuscript/corrected_20260905'
for folder in ['final_main','final_supp']:
    files = sorted((base/folder).glob('page-*.png'), key=lambda p: int(p.stem.split('-')[-1]))
    for start in range(0,len(files),12):
        sheet = Image.new('RGB',(1200,1700),'#cccccc')
        for j,f in enumerate(files[start:start+12]):
            im=Image.open(f).convert('RGB'); im.thumbnail((390,530))
            x=(j%3)*400; y=(j//3)*425
            im.thumbnail((390,395))
            sheet.paste(im,(x,y+25));ImageDraw.Draw(sheet).text((x+5,y+5),f.name,fill='black')
        sheet.save(base/f'{folder}_contact_{start//12}.jpg')
