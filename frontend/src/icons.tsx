import type { SVGProps } from "react";

type IconProps = SVGProps<SVGSVGElement>;

function IconBase({ children, ...props }: IconProps) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" {...props}>
      {children}
    </svg>
  );
}

export function CopyIcon(props: IconProps) {
  return <IconBase {...props}><rect x="8" y="8" width="11" height="11" rx="2" /><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2" /></IconBase>;
}

export function TrashIcon(props: IconProps) {
  return <IconBase {...props}><path d="M4 7h16M9 7V4h6v3m3 0-1 13H7L6 7m4 4v5m4-5v5" /></IconBase>;
}

export function KeyIcon(props: IconProps) {
  return <IconBase {...props}><circle cx="8" cy="15" r="4" /><path d="m11 12 8-8m-3 3 2 2m-5 1 2 2" /></IconBase>;
}

export function LogoutIcon(props: IconProps) {
  return <IconBase {...props}><path d="M10 5H5v14h5m4-4 4-3-4-3m4 3H9" /></IconBase>;
}

export function CloseIcon(props: IconProps) {
  return <IconBase {...props}><path d="m6 6 12 12M18 6 6 18" /></IconBase>;
}

export function CheckIcon(props: IconProps) {
  return <IconBase {...props}><path d="m5 12 4 4L19 6" /></IconBase>;
}

export function ImageIcon(props: IconProps) {
  return <IconBase {...props}><rect x="3" y="4" width="18" height="16" rx="2" /><circle cx="9" cy="10" r="2" /><path d="m21 15-5-5L5 20" /></IconBase>;
}

export function ExpandIcon(props: IconProps) {
  return <IconBase {...props}><path d="M8 3H3v5m13-5h5v5M8 21H3v-5m18 0v5h-5" /></IconBase>;
}
