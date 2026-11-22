import re

p = r"D:\code\Vivado\Loongarch_workspace\local_ci\loongarch_emu.py"
s = open(p, encoding="utf-8").read()
start = s.index("    def _exec(self, ins):")
end = s.index("    def _s32(self, v):")

new_code = open(r"D:\code\Vivado\Loongarch_workspace\local_ci\emu_decoder_body.py",
                encoding="utf-8").read()

s = s[:start] + new_code + s[end:]
open(p, "w", encoding="utf-8").write(s)
print("decoder spliced")
